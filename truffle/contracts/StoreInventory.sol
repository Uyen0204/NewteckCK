// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

// Khai báo trước cấu trúc từ ItemsManagement
contract ItemsManagement { // Tên hợp đồng, không phải tên interface
    struct PhysicalLocationInfo { address locationId; string name; string locationType; address manager; bool exists; address designatedSourceWarehouseAddress; }
}

// Interface cho RoleManagement để kiểm tra vai trò Quản lý Cửa hàng
interface IRoleManagement {
    function STORE_MANAGER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

// Interface cho ItemsManagement để lấy thông tin cửa hàng
interface IItemsManagement {
    function getStoreInfo(address storeAddress) external view returns (ItemsManagement.PhysicalLocationInfo memory);
    // function getItemInfo(string calldata itemId) external view; // Để xác thực nếu cần
}

// Interface cho WarehouseInventoryManagement để yêu cầu hàng
interface IWarehouseInventoryManagement {
    function requestStockTransferToStore(
        address requestingStoreManager,     // Quản lý CH yêu cầu
        address storeAddress,               // Cửa hàng yêu cầu
        address designatedWarehouseAddress, // Kho nguồn chỉ định
        string calldata itemId,             // Mặt hàng
        uint256 quantity                    // Số lượng
    ) external returns (uint256 internalTransferId); // Trả về ID giao dịch chuyển nội bộ
}

// Hợp đồng Quản lý Tồn kho Cửa hàng
contract StoreInventoryManagement is Ownable {
    IRoleManagement public roleManagementExternal;
    IItemsManagement public itemsManagementExternal;
    IWarehouseInventoryManagement public warehouseInventoryManagementExternal; // Hợp đồng Quản lý Tồn kho Chính

    // Tồn kho cửa hàng: storeAddress => itemId => quantity
    mapping(address => mapping(string => uint256)) public storeStockLevels;

    // Có thể theo dõi các yêu cầu đang chờ xử lý nếu cần chi tiết
    // struct WarehouseTransferRequest { ... }
    // mapping(uint256 => WarehouseTransferRequest) public pendingTransfers;

    // Sự kiện
    event StockRequestedFromWarehouse(
        address indexed storeAddress,       // indexed
        address indexed designatedWarehouse,// indexed
        string itemId,                      // KHÔNG indexed
        uint256 quantity, 
        uint256 indexed wimTransferId,    // indexed
        address byStoreManager              // KHÔNG indexed
    );
    event StockReceivedAtStore(address indexed storeAddress, string indexed itemId, uint256 quantity, address indexed fromWarehouse, uint256 wimTransferId); // Hàng được nhận tại cửa hàng
    event StockDeductedForSale(address indexed storeAddress, string indexed itemId, uint256 quantityDeducted, uint256 indexed customerOrderId); // Tồn kho bị trừ cho đơn hàng bán
    event StoreStockAdjusted(address indexed storeAddress, string indexed itemId, int256 quantityChange, string reason, address indexed byAdminOrManager); // Tồn kho cửa hàng được điều chỉnh

    constructor(address _roleManagementAddress, address _itemsManagementAddress) Ownable() {
        require(_roleManagementAddress != address(0), "SIM: Dia chi RM khong hop le"); // SIM: Địa chỉ RM không hợp lệ
        roleManagementExternal = IRoleManagement(_roleManagementAddress);
        require(_itemsManagementAddress != address(0), "SIM: Dia chi ItemsM khong hop le"); // SIM: Địa chỉ ItemsM không hợp lệ
        itemsManagementExternal = IItemsManagement(_itemsManagementAddress);
    }

    // Modifier chỉ cho phép Quản lý Cửa hàng của cửa hàng được chỉ định
    modifier onlyStoreManager(address _storeAddress) {
        ItemsManagement.PhysicalLocationInfo memory storeInfo = itemsManagementExternal.getStoreInfo(_storeAddress);
        require(storeInfo.exists, "SIM: Cua hang chua duoc dang ky trong ItemsM"); // SIM: Cửa hàng chưa được đăng ký trong ItemsM
        require(storeInfo.manager == msg.sender, "SIM: Nguoi goi khong phai quan ly cua hang nay"); // SIM: Người gọi không phải quản lý của hàng này
        bytes32 smRole = roleManagementExternal.STORE_MANAGER_ROLE();
        require(roleManagementExternal.hasRole(smRole, msg.sender), "SIM: Nguoi goi thieu vai tro QUAN_LY_CH"); // SIM: Người gọi thiếu vai trò QUAN_LY_CH
        _;
    }

    // --- HÀM SETTER (Chỉ Owner) ---
    function setWarehouseInventoryManagementAddress(address _wimAddress) external onlyOwner {
        require(_wimAddress != address(0), "SIM: Dia chi WIM khong hop le"); // SIM: Địa chỉ WIM không hợp lệ
        warehouseInventoryManagementExternal = IWarehouseInventoryManagement(_wimAddress);
    }

    // --- CÁC HÀM CỐT LÕI ---

    // Được gọi bởi Quản lý Cửa hàng để lấy hàng từ kho nguồn chỉ định của họ
    function requestStockFromDesignatedWarehouse(
        address _storeAddress,          // Cửa hàng yêu cầu
        string calldata _itemId,         // Mặt hàng
        uint256 _quantity               // Số lượng
    ) external onlyStoreManager(_storeAddress) {
        require(address(warehouseInventoryManagementExternal) != address(0), "SIM: Dia chi WIM chua duoc dat"); // SIM: Địa chỉ WIM chưa được đặt
        require(_quantity > 0, "SIM: So luong phai la so duong"); // SIM: Số lượng phải là số dương

        ItemsManagement.PhysicalLocationInfo memory storeInfo = itemsManagementExternal.getStoreInfo(_storeAddress); // Đã lấy bởi modifier
        require(storeInfo.designatedSourceWarehouseAddress != address(0), "SIM: Cua hang khong co kho nguon chi dinh"); // SIM: Cửa hàng không có kho nguồn chỉ định

        uint256 wimTransferId = warehouseInventoryManagementExternal.requestStockTransferToStore(
            msg.sender, // Quản lý cửa hàng đang yêu cầu
            _storeAddress,
            storeInfo.designatedSourceWarehouseAddress,
            _itemId,
            _quantity
        );
        
        emit StockRequestedFromWarehouse(_storeAddress, storeInfo.designatedSourceWarehouseAddress, _itemId, _quantity, wimTransferId, msg.sender);
    }

    // Được gọi bởi WarehouseInventoryManagement sau khi đã xử lý việc chuyển hàng
    function confirmStockReceivedFromWarehouse(
        address _storeAddress,          // Cửa hàng nhận
        string calldata _itemId,         // Mặt hàng
        uint256 _quantity,              // Số lượng
        address _fromWarehouseAddress,  // Kho đã gửi hàng
        uint256 _internalTransferId     // ID giao dịch chuyển nội bộ từ WIM để đối chiếu
    ) external {
        require(msg.sender == address(warehouseInventoryManagementExternal), "SIM: Nguoi goi khong phai WIM"); // SIM: Người gọi không phải WIM
        // Nếu có theo dõi pendingTransfers:
        // require(pendingTransfers[_internalTransferId].transferId != 0 && !pendingTransfers[_internalTransferId].received, "SIM: Giao dich khong hop le hoac da nhan");
        // pendingTransfers[_internalTransferId].received = true;
        // pendingTransfers[_internalTransferId].receivedTimestamp = block.timestamp;
        
        storeStockLevels[_storeAddress][_itemId] += _quantity;
        emit StockReceivedAtStore(_storeAddress, _itemId, _quantity, _fromWarehouseAddress, _internalTransferId);

        // Tùy chọn: Thông báo cho CustomerOrderManagement nếu việc nhập kho này là cho một đơn hàng đang chờ
        // Điều này đòi hỏi logic theo dõi phức tạp hơn (liên kết đơn hàng khách với yêu cầu nhập kho)
    }

    // Được gọi bởi CustomerOrderManagement khi một đơn hàng được hoàn thành và cần trừ tồn kho
    function deductStockForCustomerSale(
        address _storeAddress,          // Cửa hàng bán
        string calldata _itemId,         // Mặt hàng
        uint256 _quantity,              // Số lượng
        uint256 _customerOrderId        // ID đơn hàng của khách
    ) external { // Được gọi bởi COM, msg.sender nên là địa chỉ COM
        // require(msg.sender == address(customerOrderManagementExternal), "SIM: Nguoi goi khong phai COM");
        require(_quantity > 0, "SIM: So luong tru phai la so duong"); // SIM: Số lượng trừ phải là số dương
        
        uint256 currentStock = storeStockLevels[_storeAddress][_itemId];
        require(currentStock >= _quantity, "SIM: Khong du ton kho cua hang de ban"); // SIM: Không đủ tồn kho cửa hàng để bán
        
        storeStockLevels[_storeAddress][_itemId] = currentStock - _quantity;
        emit StockDeductedForSale(_storeAddress, _itemId, _quantity, _customerOrderId);
    }

    // --- CÁC HÀM ADMIN/QUẢN LÝ ---
    function adjustStoreStockManually(
        address _storeAddress,
        string calldata _itemId,
        int256 _quantityChange,      // Có thể âm hoặc dương
        string calldata _reason
    ) external { // Có thể là onlyOwner hoặc onlyStoreManager(_storeAddress)
        // Ví dụ: chỉ cho phép quản lý của cửa hàng đó
        ItemsManagement.PhysicalLocationInfo memory storeInfo = itemsManagementExternal.getStoreInfo(_storeAddress);
        require(storeInfo.exists && storeInfo.manager == msg.sender, "SIM: Nguoi goi khong phai quan ly duoc uy quyen cho ton kho cua hang nay"); // SIM: Người gọi không phải quản lý được ủy quyền cho tồn kho của hàng này
        bytes32 smRole = roleManagementExternal.STORE_MANAGER_ROLE();
        require(roleManagementExternal.hasRole(smRole, msg.sender), "SIM: Nguoi goi thieu vai tro QUAN_LY_CH"); // SIM: Người gọi thiếu vai trò QUAN_LY_CH

        uint256 currentStock = storeStockLevels[_storeAddress][_itemId];
        if (_quantityChange > 0) {
            storeStockLevels[_storeAddress][_itemId] = currentStock + uint256(_quantityChange);
        } else if (_quantityChange < 0) {
            uint256 amountToDecrease = uint256(-_quantityChange);
            require(currentStock >= amountToDecrease, "SIM: Dieu chinh thu cong dan den ton kho am"); // SIM: Điều chỉnh thủ công dẫn đến tồn kho âm
            storeStockLevels[_storeAddress][_itemId] = currentStock - amountToDecrease;
        } else {
            revert("SIM: Thay doi so luong khong the bang khong"); // SIM: Thay đổi số lượng không thể bằng không
        }
        emit StoreStockAdjusted(_storeAddress, _itemId, _quantityChange, _reason, msg.sender);
    }

    // --- CÁC HÀM XEM (VIEW FUNCTIONS) ---
    function getStoreStockLevel(address _storeAddress, string calldata _itemId) external view returns (uint256) {
        return storeStockLevels[_storeAddress][_itemId];
    }
}
