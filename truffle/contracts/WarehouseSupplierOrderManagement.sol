// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0; // Hoặc ^0.8.18 như bạn đã dùng trước đó

import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; // Kiểm tra lại đường dẫn nếu dùng OZ v4+ là @openzeppelin/contracts/security/ReentrancyGuard.sol
import "@openzeppelin/contracts/access/Ownable.sol";

// --- FORWARD DECLARATIONS FOR STRUCTS FROM ItemsManagement ---
// Khai báo các struct mà IItemsManagement sẽ trả về hoặc WSOM sẽ sử dụng
// Đảm bảo các trường trong struct này khớp với định nghĩa trong ItemsManagement.sol

// Struct này cần khớp với khai báo trong ItemsManagement.sol
// Nếu ItemsManagement.sol thay đổi struct này, bạn cũng cần cập nhật ở đây.
struct PhysicalLocationInfo_WSOM { // Đặt tên khác để tránh xung đột nếu ItemsManagement.sol cũng được import đầy đủ
    address locationId; 
    string name; 
    string locationType; 
    address manager; 
    bool exists; 
    // Thêm các trường khác nếu có trong PhysicalLocationInfo của ItemsManagement mà bạn cần ở đây
    // Ví dụ: bool isApprovedByBoard;
    // Ví dụ: address designatedSourceWarehouseAddress;
}

struct SupplierInfo_WSOM { // Đặt tên khác
    address supplierId; 
    string name; 
    bool isApprovedByBoard; 
    bool exists;
}

struct SupplierItemListing_WSOM { // Đặt tên khác
    string itemId; 
    address supplierAddress; 
    uint256 price; 
    bool isApprovedByBoard; 
    bool exists;
}
// --- END FORWARD DECLARATIONS ---


// --- INTERFACES ---
interface ICompanyTreasuryManager {
    function requestEscrowForSupplierOrder(address warehouseAddress, address supplierAddress, string calldata supplierOrderId, uint256 amount) external returns (bool success);
    function releaseEscrowToSupplier(address supplierAddress, string calldata supplierOrderId, uint256 amount) external returns (bool success);
    function refundEscrowToTreasury(address warehouseAddress, string calldata supplierOrderId, uint256 amount) external returns (bool success);
    function getWarehouseSpendingPolicy(address warehouseAddress, address supplierAddress) external view returns (uint256 maxAmountPerOrder);
    function getWarehouseSpendingThisPeriod(address warehouseAddress) external view returns (uint256 currentSpending);
    function WAREHOUSE_SPENDING_LIMIT_PER_PERIOD_CONST() external view returns (uint256 limit); // Đã sửa tên hàm
}

interface IRoleManagement {
    function WAREHOUSE_MANAGER_ROLE() external view returns (bytes32);
    function SUPPLIER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IItemsManagement {
    // Các hàm giờ đây sẽ trả về các struct đã được "forward declared" ở trên
    function getWarehouseInfo(address warehouseAddress) external view returns (PhysicalLocationInfo_WSOM memory);
    function getSupplierInfo(address supplierAddress) external view returns (SupplierInfo_WSOM memory);
    function getSupplierItemDetails(address supplierAddress, string calldata itemId) external view returns (SupplierItemListing_WSOM memory);
}

interface IWarehouseInventoryManagement { // Đã đổi tên từ IInventoryManagement
    function recordStockInFromSupplier(address warehouseAddress, string calldata itemId, uint256 quantity, uint256 wsOrderId) external;
}
// --- END INTERFACES ---


contract WarehouseSupplierOrderManagement is ReentrancyGuard, Ownable {
    IRoleManagement public immutable roleManagement;
    IItemsManagement public immutable itemsManagement; // Instance của interface
    ICompanyTreasuryManager public immutable companyTreasuryManager;
    IWarehouseInventoryManagement public warehouseInventoryManagement;

    uint256 public nextWSOrderId;

    enum WSOrderStatus { PendingShipment, ShippedBySupplier, ReceivedByWarehouse, CancelledByWarehouse, CancelledBySupplier }
    struct WSOrderItem { string itemId; uint256 quantity; uint256 unitPrice; }
    struct WSOrder {
        uint256 wsOrderId;
        address warehouseAddress;
        address warehouseManager;
        address supplierAddress;
        WSOrderItem[] items;
        uint256 totalAmount;
        WSOrderStatus status;
        uint256 creationTimestamp;
        uint256 lastUpdateTimestamp;
        bool fundsEscrowed;
        bool fundsReleasedToSupplier;
        string internalSupplierOrderId;
    }
    struct WSOrderItemInput { string itemId; uint256 quantity; }

    mapping(uint256 => WSOrder) public wsOrders;
    mapping(address => uint256[]) public warehouseSentOrderIds;
    mapping(address => uint256[]) public supplierReceivedOrderIds;

    event WSOrderPlaced(uint256 indexed wsOrderId, address indexed warehouseAddress, address indexed supplierAddress, uint256 totalAmount, string internalSupplierOrderId);
    event WSOrderShipmentConfirmedBySupplier(uint256 indexed wsOrderId, address indexed supplierAddress);
    event WSOrderReceiptConfirmedByWarehouse(uint256 indexed wsOrderId, address indexed warehouseManager);
    event WSOrderCancelledByWarehouse(uint256 indexed wsOrderId, address indexed warehouseManager, string reason);
    event WSOrderCancelledBySupplier(uint256 indexed wsOrderId, address indexed supplierAddress, string reason);
    event WSOrderFundsReleasedToSupplier(uint256 indexed wsOrderId, address indexed supplierAddress, uint256 amount);
    event EscrowRequestedForWSOrder(uint256 indexed wsOrderId, uint256 amount);
    event WSOrderStatusUpdated(uint256 indexed wsOrderId, WSOrderStatus newStatus, uint256 timestamp);
    event WarehouseInventoryManagementAddressSet(address indexed wimAddress);

    constructor(
        address _roleManagementAddress,
        address _itemsManagementAddress,
        address _companyTreasuryManagerAddress
    ) Ownable() {
        require(_roleManagementAddress != address(0), "WSOM: Dia chi RM khong hop le");
        require(_itemsManagementAddress != address(0), "WSOM: Dia chi ItemsM khong hop le");
        require(_companyTreasuryManagerAddress != address(0), "WSOM: Dia chi CTM khong hop le");

        roleManagement = IRoleManagement(_roleManagementAddress);
        itemsManagement = IItemsManagement(_itemsManagementAddress);
        companyTreasuryManager = ICompanyTreasuryManager(_companyTreasuryManagerAddress);
        nextWSOrderId = 1;
    }

    function setWarehouseInventoryManagementAddress(address _wimAddress) external onlyOwner {
        require(_wimAddress != address(0), "WSOM: Dia chi WIM khong hop le");
        warehouseInventoryManagement = IWarehouseInventoryManagement(_wimAddress);
        emit WarehouseInventoryManagementAddressSet(_wimAddress);
    }

    modifier onlyWarehouseManagerForAction(address _warehouseAddress) {
        // Sử dụng struct đã forward declared
        PhysicalLocationInfo_WSOM memory warehouseInfo = itemsManagement.getWarehouseInfo(_warehouseAddress);
        require(warehouseInfo.exists, "WSOM: Kho khong ton tai");
        require(warehouseInfo.manager == msg.sender, "WSOM: Nguoi goi khong phai quan ly kho nay");
        bytes32 whManagerRole = roleManagement.WAREHOUSE_MANAGER_ROLE();
        require(roleManagement.hasRole(whManagerRole, msg.sender), "WSOM: Nguoi goi thieu vai tro QUAN_LY_KHO");
        _;
    }

    modifier onlyOrderWarehouseManager(uint256 _wsOrderId) {
        require(wsOrders[_wsOrderId].wsOrderId != 0, "WSOM: Don hang khong ton tai");
        require(wsOrders[_wsOrderId].warehouseManager == msg.sender, "WSOM: Nguoi goi khong phai quan ly kho cua don hang");
        bytes32 whManagerRole = roleManagement.WAREHOUSE_MANAGER_ROLE();
        require(roleManagement.hasRole(whManagerRole, msg.sender), "WSOM: Nguoi goi thieu vai tro QUAN_LY_KHO");
        _;
    }

    modifier onlyOrderSupplier(uint256 _wsOrderId) {
        require(wsOrders[_wsOrderId].wsOrderId != 0, "WSOM: Don hang khong ton tai");
        require(wsOrders[_wsOrderId].supplierAddress == msg.sender, "WSOM: Nguoi goi khong phai NCC cua don hang");
        bytes32 supRole = roleManagement.SUPPLIER_ROLE();
        require(roleManagement.hasRole(supRole, msg.sender), "WSOM: Nguoi goi thieu vai tro NCC");
        _;
    }

    function placeOrderByWarehouse(
        address _warehouseAddress,
        address _supplierAddress,
        WSOrderItemInput[] calldata _itemsInput
    ) external onlyWarehouseManagerForAction(_warehouseAddress) nonReentrant {
        require(address(warehouseInventoryManagement) != address(0), "WSOM: Dia chi WIM chua duoc dat");
        require(_itemsInput.length > 0, "WSOM: Don hang phai co it nhat mot mat hang");
        
        // Sử dụng struct đã forward declared
        SupplierInfo_WSOM memory supplierInfo = itemsManagement.getSupplierInfo(_supplierAddress);
        require(supplierInfo.exists && supplierInfo.isApprovedByBoard, "WSOM: NCC khong hop le hoac chua duoc phe duyet");

        uint256 currentWsOrderId = nextWSOrderId++;
        string memory internalOrderIdForEscrow = string(abi.encodePacked("WSOM-", uintToString(currentWsOrderId)));

        WSOrder storage newOrder = wsOrders[currentWsOrderId];
        newOrder.wsOrderId = currentWsOrderId;
        newOrder.warehouseAddress = _warehouseAddress;
        newOrder.warehouseManager = msg.sender;
        newOrder.supplierAddress = _supplierAddress;
        newOrder.status = WSOrderStatus.PendingShipment;
        newOrder.creationTimestamp = block.timestamp;
        newOrder.lastUpdateTimestamp = block.timestamp;
        newOrder.internalSupplierOrderId = internalOrderIdForEscrow;

        uint256 calculatedTotalAmount = 0;
        for (uint i = 0; i < _itemsInput.length; i++) {
            WSOrderItemInput calldata itemInput = _itemsInput[i];
            require(itemInput.quantity > 0, "WSOM: So luong mat hang phai la so duong");
            
            // SỬA Ở ĐÂY: Sử dụng SupplierItemListing_WSOM đã được khai báo ở phạm vi toàn cục (file-level)
            SupplierItemListing_WSOM memory supplierListing = itemsManagement.getSupplierItemDetails(_supplierAddress, itemInput.itemId);
            
            require(supplierListing.exists && supplierListing.isApprovedByBoard, "WSOM: Mat hang cua NCC khong co san hoac chua duoc phe duyet boi BDH");
            
            newOrder.items.push(WSOrderItem({itemId: itemInput.itemId, quantity: itemInput.quantity, unitPrice: supplierListing.price}));
            calculatedTotalAmount += supplierListing.price * itemInput.quantity;
        }
        newOrder.totalAmount = calculatedTotalAmount;

        uint256 maxAmountPerOrderPolicy = companyTreasuryManager.getWarehouseSpendingPolicy(_warehouseAddress, _supplierAddress);
        uint256 currentSpendingThisPeriod = companyTreasuryManager.getWarehouseSpendingThisPeriod(_warehouseAddress);
        uint256 spendingLimitPerPeriod = companyTreasuryManager.WAREHOUSE_SPENDING_LIMIT_PER_PERIOD_CONST();
        
        require(maxAmountPerOrderPolicy > 0, "WSOM: Khong co chinh sach chi tieu tu Ngan quy cho Kho/NCC nay");
        require(calculatedTotalAmount <= maxAmountPerOrderPolicy, "WSOM: Gia tri don hang vuot qua chinh sach Ngan quy moi don");
        uint256 projectedSpending = currentSpendingThisPeriod + calculatedTotalAmount;
        require(projectedSpending <= spendingLimitPerPeriod, "WSOM: Don hang vuot qua gioi han chi tieu dinh ky cua Ngan quy");

        bool escrowSuccess = companyTreasuryManager.requestEscrowForSupplierOrder(
            _warehouseAddress, _supplierAddress, internalOrderIdForEscrow, calculatedTotalAmount
        );
        require(escrowSuccess, "WSOM: Ky quy tien tu CTM that bai");
        newOrder.fundsEscrowed = true;

        warehouseSentOrderIds[_warehouseAddress].push(currentWsOrderId);
        supplierReceivedOrderIds[_supplierAddress].push(currentWsOrderId);

        emit EscrowRequestedForWSOrder(currentWsOrderId, calculatedTotalAmount);
        emit WSOrderPlaced(currentWsOrderId, _warehouseAddress, _supplierAddress, calculatedTotalAmount, internalOrderIdForEscrow);
        emit WSOrderStatusUpdated(currentWsOrderId, newOrder.status, block.timestamp);
    }

    function supplierConfirmShipment(uint256 _wsOrderId) external onlyOrderSupplier(_wsOrderId) nonReentrant {
        WSOrder storage currentOrder = wsOrders[_wsOrderId];
        require(currentOrder.status == WSOrderStatus.PendingShipment, "WSOM: Don hang khong o trang thai cho giao hang");
        currentOrder.status = WSOrderStatus.ShippedBySupplier;
        currentOrder.lastUpdateTimestamp = block.timestamp;
        emit WSOrderShipmentConfirmedBySupplier(_wsOrderId, msg.sender);
        emit WSOrderStatusUpdated(_wsOrderId, currentOrder.status, block.timestamp);
    }

    function warehouseConfirmReceipt(uint256 _wsOrderId) external onlyOrderWarehouseManager(_wsOrderId) nonReentrant {
        WSOrder storage currentOrder = wsOrders[_wsOrderId];
        require(currentOrder.status == WSOrderStatus.ShippedBySupplier, "WSOM: Don hang chua duoc NCC giao");
        require(currentOrder.fundsEscrowed, "WSOM: Tien chua duoc ky quy");
        require(!currentOrder.fundsReleasedToSupplier, "WSOM: Tien da duoc giai ngan");
        require(address(warehouseInventoryManagement) != address(0), "WSOM: Dia chi WIM chua duoc dat");

        bool releaseSuccess = companyTreasuryManager.releaseEscrowToSupplier(
            currentOrder.supplierAddress, currentOrder.internalSupplierOrderId, currentOrder.totalAmount
        );
        require(releaseSuccess, "WSOM: Giai ngan tien cho NCC tu CTM that bai");

        currentOrder.status = WSOrderStatus.ReceivedByWarehouse;
        currentOrder.fundsReleasedToSupplier = true;
        currentOrder.lastUpdateTimestamp = block.timestamp;

        for (uint i = 0; i < currentOrder.items.length; i++) {
            WSOrderItem memory item = currentOrder.items[i];
            warehouseInventoryManagement.recordStockInFromSupplier(
                currentOrder.warehouseAddress, item.itemId, item.quantity, _wsOrderId
            );
        }
        emit WSOrderReceiptConfirmedByWarehouse(_wsOrderId, msg.sender);
        emit WSOrderFundsReleasedToSupplier(_wsOrderId, currentOrder.supplierAddress, currentOrder.totalAmount);
        emit WSOrderStatusUpdated(_wsOrderId, currentOrder.status, block.timestamp);
    }

    function cancelOrderByWarehouse(uint256 _wsOrderId, string calldata _reason)
        external onlyOrderWarehouseManager(_wsOrderId) nonReentrant {
        _internalCancelOrder(_wsOrderId, WSOrderStatus.CancelledByWarehouse);
        emit WSOrderCancelledByWarehouse(_wsOrderId, msg.sender, _reason);
    }

    function cancelOrderBySupplier(uint256 _wsOrderId, string calldata _reason)
        external onlyOrderSupplier(_wsOrderId) nonReentrant {
        _internalCancelOrder(_wsOrderId, WSOrderStatus.CancelledBySupplier);
        emit WSOrderCancelledBySupplier(_wsOrderId, msg.sender, _reason);
    }

    function _internalCancelOrder(uint256 _wsOrderId, WSOrderStatus _newStatus) internal {
        WSOrder storage currentOrder = wsOrders[_wsOrderId];
        require(currentOrder.status == WSOrderStatus.PendingShipment, "WSOM: Don hang khong o trang thai co the huy");
        require(currentOrder.fundsEscrowed, "WSOM: Tien chua duoc ky quy de huy");

        bool refundSuccess = companyTreasuryManager.refundEscrowToTreasury(
            currentOrder.warehouseAddress, currentOrder.internalSupplierOrderId, currentOrder.totalAmount
        );
        require(refundSuccess, "WSOM: Hoan tra tien ky quy CTM that bai, viec huy bi hoan tac");

        currentOrder.status = _newStatus;
        currentOrder.lastUpdateTimestamp = block.timestamp;
        emit WSOrderStatusUpdated(_wsOrderId, currentOrder.status, block.timestamp);
    }

    function getWSOrderDetails(uint256 _wsOrderId) external view returns (WSOrder memory) {
        require(wsOrders[_wsOrderId].wsOrderId != 0, "WSOM: Don hang khong tim thay");
        return wsOrders[_wsOrderId];
    }
    function getWarehouseSentOrders(address _warehouse) external view returns (uint256[] memory) { return warehouseSentOrderIds[_warehouse]; }
    function getSupplierReceivedOrders(address _supplier) external view returns (uint256[] memory) { return supplierReceivedOrderIds[_supplier]; }

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        uint256 i = digits;
        while (value != 0) { i--; buffer[i] = bytes1(uint8(48 + (value % 10))); value /= 10; }
        return string(buffer);
    }
}