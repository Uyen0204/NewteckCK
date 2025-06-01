// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Khai báo trước cấu trúc từ ItemsManagement
contract ItemsManagement {
    struct PhysicalLocationInfo { address locationId; string name; string locationType; address manager; bool exists; address designatedSourceWarehouseAddress;}
}

// Interface cho RoleManagement
interface IRoleManagement {
    function STORE_MANAGER_ROLE() external view returns (bytes32);
    // function WAREHOUSE_MANAGER_ROLE() external view returns (bytes32); // Not directly used by COM anymore
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32); // For setXyzAddress if Ownable is not used for that
    function hasRole(bytes32 role, address account) external view returns (bool);
}

// Interface cho ItemsManagement
interface IItemsManagement {
    function getStoreInfo(address storeAddress) external view returns (ItemsManagement.PhysicalLocationInfo memory);
    function getItemRetailPriceAtStore(string calldata itemId, address storeAddress) external view returns (uint256 price, bool priceExists);
}

// Interface cho StoreInventoryManagement
interface IStoreInventoryManagement {
    function getStoreStockLevel(address storeAddress, string calldata itemId) external view returns (uint256);
    function deductStockForCustomerSale(address storeAddress, string calldata itemId, uint256 quantity, uint256 customerOrderId) external;
}

// Interface cho WarehouseInventoryManagement (cho việc trả hàng)
interface IWarehouseInventoryManagement {
    function recordReturnedStockByCustomer(
        address returnToWarehouseAddress,
        string calldata itemId,
        uint256 quantity,
        uint256 customerOrderId
    ) external;
}

// MỚI: Interface cho CompanyTreasuryManager để gọi hàm hoàn tiền
interface ICompanyTreasuryManager {
    function refundCustomerOrderFromTreasury(uint256 orderId, address payable customerAddress, uint256 amountToRefund) external;
}

// Hợp đồng Quản lý Đơn hàng Khách hàng
contract CustomerOrderManagement is ReentrancyGuard, Ownable {
    IRoleManagement public immutable roleManagement;
    IItemsManagement public immutable itemsManagement;
    IStoreInventoryManagement public storeInventoryManagement; // Main inventory interaction
    IWarehouseInventoryManagement public warehouseInventoryManagement; // For returns
    
    address public immutable companyTreasuryAddress; // Địa chỉ của CompanyTreasuryManager

    uint256 public nextOrderId;     // ID cho đơn hàng tiếp theo

    // Trạng thái đơn hàng của khách
    enum OrderStatus {
        Placed,                     // 0: Khách đặt, thanh toán được COM giữ
        ProcessingByStore,          // 1: Cửa hàng đang kiểm tra tồn kho / khởi tạo bổ sung hàng
        AllItemsReadyForDelivery,   // 2: Tất cả mặt hàng đã sẵn sàng tại cửa hàng cho đơn này (đã bỏ trạng thái partiellement)
        DeliveryConfirmedByStore,   // 3: Cửa hàng xác nhận đã giao hàng / khách đã lấy
        Completed,                  // 4: Khách xác nhận nhận hàng, tiền được giải ngân cho Ngân quỹ
        CancelledByStore,           // 5: Cửa hàng hủy
        CancelledByCustomer,        // 6: Khách hủy trước khi giao hàng
        ReturnedByCustomer          // 7: Khách trả hàng sau khi nhận
    }

    // Trạng thái của từng mặt hàng trong đơn, do cửa hàng quản lý
    enum OrderItemStatus { 
        PendingStoreProcessing,     // Ban đầu
        StoreStockAvailable,        // Cửa hàng có hàng
        StoreNeedsRestock,          // Cửa hàng cần đặt thêm (trạng thái tùy chọn)
        ReadyForDelivery,           // Mặt hàng đã được cửa hàng xử lý và sẵn sàng
        DeliveredToCustomer         // Mặt hàng được xác nhận là một phần của lần giao cuối cùng
    }

    // Mặt hàng trong đơn (đơn giản hóa, tập trung vào những gì khách thấy)
    struct OrderItem {
        string itemId;          // ID mặt hàng
        uint256 quantity;       // Số lượng
        uint256 unitPrice;      // Giá bán lẻ tại cửa hàng tại thời điểm đặt hàng
        OrderItemStatus status; // Trạng thái mặt hàng
    }

    // Cấu trúc đơn hàng
    struct Order {
        uint256 orderId;            // ID đơn hàng
        address customerAddress;    // Địa chỉ khách hàng
        address storeAddress;       // Cửa hàng khách đã chọn
        OrderItem[] items;          // Danh sách mặt hàng
        uint256 totalAmountPaid;    // Số tiền khách đã trả cho hợp đồng này
        OrderStatus status;         // Trạng thái đơn hàng
        uint256 creationTimestamp;  // Thời điểm tạo
        uint256 lastUpdateTimestamp;// Thời điểm cập nhật cuối
        bool fundsReleasedToCompany;// Tiền đã giải ngân cho công ty chưa?
    }

    // Dữ liệu đầu vào từ khách hàng (đơn giản hóa: chỉ itemId và quantity)
    struct OrderItemInput {
        string itemId;
        uint256 quantity;
    }

    mapping(uint256 => Order) public orders; // orderId => Chi tiết đơn hàng
    mapping(address => uint256[]) public customerOrderIds; // customerAddress => Danh sách ID đơn hàng của khách
    mapping(address => uint256[]) public storeAssignedOrderIds; // storeAddress => Danh sách ID đơn hàng được giao cho cửa hàng

    // Sự kiện
    event OrderPlaced(uint256 indexed orderId, address indexed customer, address indexed storeAddress, uint256 totalAmount); // Đơn hàng được đặt
    event OrderItemStatusUpdatedByStore(uint256 indexed orderId, uint256 itemIndex, string itemId, OrderItemStatus newItemStatus, address indexed storeManager); // Trạng thái mặt hàng được cửa hàng cập nhật
    event OrderReadyForDelivery(uint256 indexed orderId, address indexed storeAddress, address indexed storeManager); // Đơn hàng sẵn sàng để giao
    event OrderDeliveryConfirmedByStore(uint256 indexed orderId, address indexed storeAddress, address indexed storeManager); // Cửa hàng xác nhận giao hàng
    event OrderCompletedByCustomer(uint256 indexed orderId, address indexed customer); // Khách hàng hoàn thành đơn hàng
    event FundsReleasedToCompany(uint256 indexed orderId, uint256 amount, address indexed treasury); // Tiền được giải ngân cho công ty
    event OrderOverallStatusUpdated(uint256 indexed orderId, OrderStatus newStatus, uint256 timestamp); // Trạng thái tổng thể đơn hàng được cập nhật
    event OrderCancelled(uint256 indexed orderId, address indexed canceller, OrderStatus newStatus, string reason); // Đơn hàng bị hủy
    event OrderReturnedByCustomerNotified(uint256 indexed orderId, address indexed customer, address returnToWarehouse, string reason); // Thông báo khách trả hàng
    // event FundsRefundedToCustomer(uint256 indexed orderId, address indexed customer, uint256 amount); // Sự kiện này sẽ do CTM phát ra là CustomerRefundProcessedFromTreasury
    
    // Admin events
    event StoreInventoryManagementAddressSet(address indexed simAddress); // Địa chỉ SIM được đặt
    event WarehouseInventoryManagementAddressSet(address indexed wimAddress); // Địa chỉ WIM được đặt (cho trả hàng)

    constructor(
        address _roleManagementAddress,
        address _itemsManagementAddress,
        address _companyTreasury // Đây là địa chỉ của CompanyTreasuryManager
    ) Ownable() { // Pass msg.sender to Ownable
        require(_roleManagementAddress != address(0), "COM: Dia chi RM khong hop le");
        require(_itemsManagementAddress != address(0), "COM: Dia chi ItemsM khong hop le");
        require(_companyTreasury != address(0), "COM: Dia chi ngan quy cong ty khong hop le");

        roleManagement = IRoleManagement(_roleManagementAddress);
        itemsManagement = IItemsManagement(_itemsManagementAddress);
        companyTreasuryAddress = _companyTreasury; // Lưu địa chỉ của CTM
        nextOrderId = 1;
    }

    // --- SETTERS (Owner/Admin only) ---
    function setStoreInventoryManagementAddress(address _simAddress) external onlyOwner {
        require(_simAddress != address(0), "COM: Dia chi SIM khong hop le");
        storeInventoryManagement = IStoreInventoryManagement(_simAddress);
        emit StoreInventoryManagementAddressSet(_simAddress);
    }
    function setWarehouseInventoryManagementAddress(address _wimAddress) external onlyOwner {
        require(_wimAddress != address(0), "COM: Dia chi WIM khong hop le");
        warehouseInventoryManagement = IWarehouseInventoryManagement(_wimAddress);
        emit WarehouseInventoryManagementAddressSet(_wimAddress);
    }

    // --- MODIFIERS ---
    modifier onlyOrderCustomer(uint256 _orderId) {
        require(orders[_orderId].orderId != 0, "COM: Don hang khong ton tai");
        require(orders[_orderId].customerAddress == msg.sender, "COM: Nguoi goi khong phai la khach hang");
        _;
    }

    modifier onlyStoreManagerForOrder(uint256 _orderId) {
        require(orders[_orderId].orderId != 0, "COM: Don hang khong ton tai");
        address storeAddr = orders[_orderId].storeAddress;
        require(storeAddr != address(0), "COM: Don hang khong co cua hang duoc gan");
        ItemsManagement.PhysicalLocationInfo memory storeInfo = itemsManagement.getStoreInfo(storeAddr);
        require(storeInfo.manager == msg.sender, "COM: Nguoi goi khong phai quan ly cua hang cua don hang");
        bytes32 smRole = roleManagement.STORE_MANAGER_ROLE();
        require(roleManagement.hasRole(smRole, msg.sender), "COM: Nguoi goi thieu vai tro QUAN_LY_CH");
        _;
    }

    // --- CORE ORDER FUNCTIONS ---
    function placeOrder(
        OrderItemInput[] calldata _orderItemsInput,
        address _storeAddress
    ) external payable nonReentrant {
        require(address(storeInventoryManagement) != address(0), "COM: Dia chi SIM chua duoc dat");
        require(_orderItemsInput.length > 0, "COM: Don hang phai co it nhat mot mat hang");
        itemsManagement.getStoreInfo(_storeAddress); // Kiểm tra cửa hàng hợp lệ

        uint256 currentOrderId = nextOrderId++;
        Order storage newOrder = orders[currentOrderId];
        newOrder.orderId = currentOrderId;
        newOrder.customerAddress = msg.sender;
        newOrder.storeAddress = _storeAddress;
        newOrder.status = OrderStatus.Placed;
        newOrder.creationTimestamp = block.timestamp;
        newOrder.lastUpdateTimestamp = block.timestamp;

        uint256 calculatedTotalAmount = 0;
        for (uint i = 0; i < _orderItemsInput.length; i++) {
            OrderItemInput calldata itemInput = _orderItemsInput[i];
            require(itemInput.quantity > 0, "COM: So luong mat hang phai la so duong");
            (uint256 retailPrice, bool priceExists) = itemsManagement.getItemRetailPriceAtStore(itemInput.itemId, _storeAddress);
            require(priceExists && retailPrice > 0, "COM: Gia mat hang khong hop le tai cua hang");

            newOrder.items.push(OrderItem({
                itemId: itemInput.itemId,
                quantity: itemInput.quantity,
                unitPrice: retailPrice,
                status: OrderItemStatus.PendingStoreProcessing
            }));
            calculatedTotalAmount += retailPrice * itemInput.quantity;
        }

        require(msg.value == calculatedTotalAmount, "COM: So tien thanh toan khong chinh xac");
        newOrder.totalAmountPaid = calculatedTotalAmount;

        customerOrderIds[msg.sender].push(currentOrderId);
        storeAssignedOrderIds[_storeAddress].push(currentOrderId);

        emit OrderPlaced(currentOrderId, msg.sender, _storeAddress, calculatedTotalAmount);
        emit OrderOverallStatusUpdated(currentOrderId, newOrder.status, block.timestamp);
    }

    function storeUpdateOrderItemStatus(uint256 _orderId, uint256 _itemIndex, OrderItemStatus _newStatus)
        external onlyStoreManagerForOrder(_orderId) nonReentrant {
        Order storage currentOrder = orders[_orderId];
        require(currentOrder.status == OrderStatus.Placed || currentOrder.status == OrderStatus.ProcessingByStore,
                "COM: Trang thai don hang khong cho phep cap nhat");
        require(_itemIndex < currentOrder.items.length, "COM: Chi muc mat hang khong hop le");
        OrderItem storage item = currentOrder.items[_itemIndex];
        require(_newStatus == OrderItemStatus.StoreStockAvailable || _newStatus == OrderItemStatus.StoreNeedsRestock || _newStatus == OrderItemStatus.ReadyForDelivery, 
                "COM: Trang thai cap nhat khong hop le");
        
        item.status = _newStatus;
        currentOrder.lastUpdateTimestamp = block.timestamp;
        emit OrderItemStatusUpdatedByStore(_orderId, _itemIndex, item.itemId, _newStatus, msg.sender);
        _updateOverallOrderStatusAfterStoreAction(_orderId);
    }
    
    function storeConfirmAllItemsReadyForDelivery(uint256 _orderId)
        external onlyStoreManagerForOrder(_orderId) nonReentrant {
        Order storage currentOrder = orders[_orderId];
        require(currentOrder.status == OrderStatus.ProcessingByStore, "COM: Don hang chua o trang thai dang xu ly");
        for (uint i = 0; i < currentOrder.items.length; i++) {
            require(currentOrder.items[i].status == OrderItemStatus.ReadyForDelivery, "COM: Chua du tat ca mat hang san sang");
        }
        currentOrder.status = OrderStatus.AllItemsReadyForDelivery;
        currentOrder.lastUpdateTimestamp = block.timestamp;
        emit OrderReadyForDelivery(_orderId, currentOrder.storeAddress, msg.sender);
        emit OrderOverallStatusUpdated(_orderId, currentOrder.status, block.timestamp);
    }

    function storeConfirmDeliveryToCustomer(uint256 _orderId)
        external onlyStoreManagerForOrder(_orderId) nonReentrant {
        Order storage currentOrder = orders[_orderId];
        require(currentOrder.status == OrderStatus.AllItemsReadyForDelivery, "COM: Don hang chua san sang de giao");
        for (uint i = 0; i < currentOrder.items.length; i++) {
            OrderItem storage item = currentOrder.items[i];
            require(item.status == OrderItemStatus.ReadyForDelivery, "COM: Mot mat hang chua san sang");
            storeInventoryManagement.deductStockForCustomerSale(currentOrder.storeAddress, item.itemId, item.quantity, _orderId);
            item.status = OrderItemStatus.DeliveredToCustomer;
        }
        currentOrder.status = OrderStatus.DeliveryConfirmedByStore;
        currentOrder.lastUpdateTimestamp = block.timestamp;
        emit OrderDeliveryConfirmedByStore(_orderId, currentOrder.storeAddress, msg.sender);
        emit OrderOverallStatusUpdated(_orderId, currentOrder.status, block.timestamp);
    }
    
    function customerConfirmReceipt(uint256 _orderId)
        external onlyOrderCustomer(_orderId) nonReentrant {
        Order storage currentOrder = orders[_orderId];
        require(currentOrder.status == OrderStatus.DeliveryConfirmedByStore, "COM: Cua hang chua xac nhan giao hang");
        require(!currentOrder.fundsReleasedToCompany, "COM: Tien da duoc giai ngan");

        currentOrder.status = OrderStatus.Completed;
        currentOrder.lastUpdateTimestamp = block.timestamp;
        currentOrder.fundsReleasedToCompany = true;

        (bool success, ) = payable(companyTreasuryAddress).call{value: currentOrder.totalAmountPaid}("");
        require(success, "COM: Giai ngan tien cho ngan quy cong ty that bai");

        emit OrderCompletedByCustomer(_orderId, msg.sender);
        emit FundsReleasedToCompany(_orderId, currentOrder.totalAmountPaid, companyTreasuryAddress);
        emit OrderOverallStatusUpdated(_orderId, currentOrder.status, block.timestamp);
    }

    // --- CANCELLATION AND RETURN FUNCTIONS ---
    function cancelOrderByStore(uint256 _orderId, string calldata _reason)
        external onlyStoreManagerForOrder(_orderId) nonReentrant {
        Order storage currentOrder = orders[_orderId];
        require(currentOrder.status == OrderStatus.Placed || currentOrder.status == OrderStatus.ProcessingByStore,
                "COM: Trang thai don hang khong cho phep cua hang huy");
        _internalCancelOrderAndRefund(_orderId, msg.sender, OrderStatus.CancelledByStore, _reason, 100);
    }

    function customerCancelOrderBeforeDelivery(uint256 _orderId, string calldata _reason)
        external onlyOrderCustomer(_orderId) nonReentrant {
        Order storage currentOrder = orders[_orderId];
        require(currentOrder.status < OrderStatus.DeliveryConfirmedByStore && currentOrder.status != OrderStatus.CancelledByStore,
                "COM: Trang thai don hang khong cho phep khach huy");
        _internalCancelOrderAndRefund(_orderId, msg.sender, OrderStatus.CancelledByCustomer, _reason, 100);
    }

    // Đã cập nhật: Hoàn 90% từ Ngân quỹ khi trả hàng
    function customerReturnOrderAfterReceipt(uint256 _orderId, address _returnToWarehouseAddress, string calldata _reason)
        external
        onlyOrderCustomer(_orderId)
        nonReentrant
    {
        Order storage currentOrder = orders[_orderId];
        require(currentOrder.status == OrderStatus.Completed, "COM: Don hang chua hoan thanh de co the tra lai");
        require(address(warehouseInventoryManagement) != address(0), "COM: Dia chi WIM cho viec tra hang chua duoc dat");
        require(companyTreasuryAddress != address(0), "COM: Dia chi CTM chua duoc dat de hoan tien"); // Thêm kiểm tra
        
        // 1. Ghi nhận hàng trả về cho Warehouse Inventory
        for (uint i = 0; i < currentOrder.items.length; i++) {
            OrderItem memory item = currentOrder.items[i];
            warehouseInventoryManagement.recordReturnedStockByCustomer(
                _returnToWarehouseAddress, item.itemId, item.quantity, _orderId
            );
        }

        // 2. Cập nhật trạng thái đơn hàng
        currentOrder.status = OrderStatus.ReturnedByCustomer;
        currentOrder.lastUpdateTimestamp = block.timestamp;
        // currentOrder.fundsReleasedToCompany LÀ TRUE ở đây

        // 3. Tính toán và yêu cầu hoàn tiền 90% từ CompanyTreasuryManager
        uint256 refundPercentage = 90; // Cố định 90%
        uint256 amountToRefund = (currentOrder.totalAmountPaid * refundPercentage) / 100;

        if (amountToRefund > 0) {
            // Gọi CTM để thực hiện hoàn tiền.
            ICompanyTreasuryManager(companyTreasuryAddress).refundCustomerOrderFromTreasury(
                _orderId, 
                payable(currentOrder.customerAddress), 
                amountToRefund
            );
            // CTM sẽ emit sự kiện CustomerRefundProcessedFromTreasury.
        }
        
        emit OrderReturnedByCustomerNotified(_orderId, msg.sender, _returnToWarehouseAddress, _reason);
        emit OrderOverallStatusUpdated(_orderId, currentOrder.status, block.timestamp);
    }

    // --- INTERNAL HELPER FUNCTIONS ---
    function _internalCancelOrderAndRefund(
        uint256 _orderId,
        address _canceller,
        OrderStatus _newStatus,
        string memory _reason,
        uint256 _refundPercentage
    ) internal {
        Order storage currentOrder = orders[_orderId];
        require(!currentOrder.fundsReleasedToCompany, "COM: Khong the huy/hoan tien, tien da thuoc ve cong ty");

        currentOrder.status = _newStatus;
        currentOrder.lastUpdateTimestamp = block.timestamp;

        if (_refundPercentage > 0 && currentOrder.totalAmountPaid > 0) {
            uint256 refundAmount = (currentOrder.totalAmountPaid * _refundPercentage) / 100;
            if (refundAmount > 0) {
                (bool success, ) = payable(currentOrder.customerAddress).call{value: refundAmount}("");
                require(success, "COM: Hoan tien cho khach that bai, viec huy bi hoan tac");
                // Không emit FundsRefundedToCustomer ở đây nữa nếu muốn CTM quản lý sự kiện này thống nhất
                // Nếu hủy trước khi tiền vào CTM, thì COM tự hoàn và có thể tự emit sự kiện riêng.
                // Để nhất quán, có thể bỏ event FundsRefundedToCustomer và chỉ dựa vào event của CTM
            }
        }
        emit OrderCancelled(_orderId, _canceller, _newStatus, _reason);
        emit OrderOverallStatusUpdated(_orderId, currentOrder.status, block.timestamp);
    }

    function _updateOverallOrderStatusAfterStoreAction(uint256 _orderId) internal {
        Order storage currentOrder = orders[_orderId];
        if (currentOrder.status == OrderStatus.Placed) {
             bool anyItemTouchedByStore = false;
             for(uint i=0; i < currentOrder.items.length; i++){
                 if(currentOrder.items[i].status != OrderItemStatus.PendingStoreProcessing){
                     anyItemTouchedByStore = true;
                     break;
                 }
             }
             if(anyItemTouchedByStore){
                currentOrder.status = OrderStatus.ProcessingByStore;
                currentOrder.lastUpdateTimestamp = block.timestamp;
                emit OrderOverallStatusUpdated(_orderId, currentOrder.status, block.timestamp);
             }
        }
    }

    function isOrderInFinalState(OrderStatus _status) internal pure returns (bool) {
        return _status >= OrderStatus.Completed;
    }

    // --- VIEW FUNCTIONS ---
    function getOrderDetails(uint256 _orderId) external view returns (Order memory) {
        require(orders[_orderId].orderId != 0, "COM: Don hang khong ton tai");
        return orders[_orderId];
    }
    function getOrderItems(uint256 _orderId) external view returns (OrderItem[] memory) {
        require(orders[_orderId].orderId != 0, "COM: Don hang khong ton tai");
        return orders[_orderId].items;
    }
    function getCustomerOrders(address _customer) external view returns (uint256[] memory) { return customerOrderIds[_customer]; }
    function getStoreAssignedOrders(address _store) external view returns (uint256[] memory) { return storeAssignedOrderIds[_store]; }
    
    // --- EMERGENCY/ADMIN FUNCTIONS ---
    function emergencyWithdraw(address payable _to) external onlyOwner nonReentrant { // Đã sửa để nhận _to
        require(_to != address(0), "COM: Nguoi nhan khong hop le");
        uint256 balance = address(this).balance;
        if (balance > 0) {
             // Quyết định chuyển cho _to (do owner chỉ định) hay cố định về companyTreasuryAddress
            (bool success, ) = _to.call{value: balance}("");
            // (bool success, ) = payable(companyTreasuryAddress).call{value: balance}(""); // Hoặc luôn chuyển về ngân quỹ
            require(success, "COM: Rut tien khan cap that bai");
        }
    }
}

