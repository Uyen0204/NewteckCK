// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

// Khai báo trước cấu trúc từ ItemsManagement
contract ItemsManagement { // Tên hợp đồng, không phải tên interface
    struct PhysicalLocationInfo { address locationId; string name; string locationType; address manager; bool exists; address designatedSourceWarehouseAddress; }
}

// Interface cho RoleManagement để kiểm tra vai trò Quản lý Kho
interface IRoleManagement {
    function WAREHOUSE_MANAGER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

// Interface cho ItemsManagement để lấy thông tin kho (tùy chọn)
interface IItemsManagement {
    function getWarehouseInfo(address warehouseAddress) external view returns (ItemsManagement.PhysicalLocationInfo memory);
    // Có thể không cần getItemInfo nếu tin tưởng itemId từ các hợp đồng khác
}

// Interface cho StoreInventoryManagement để thông báo khi hàng đã được chuyển
interface IStoreInventoryManagement {
    function confirmStockReceivedFromWarehouse(
        address storeAddress,       // Cửa hàng nhận
        string calldata itemId,     // Mặt hàng
        uint256 quantity,           // Số lượng
        address fromWarehouseAddress, // Kho đã gửi (địa chỉ của hợp đồng này)
        uint256 internalTransferId  // ID giao dịch chuyển nội bộ
    ) external;
}

// Hợp đồng Quản lý Tồn kho Chính (Kho trung tâm)
contract WarehouseInventoryManagement is Ownable {
    IRoleManagement public roleManagementExternal;
    IItemsManagement public itemsManagementExternal; // Tùy chọn, để kiểm tra thêm
    IStoreInventoryManagement public storeInventoryManagementExternal; // Hợp đồng Quản lý Tồn kho Cửa hàng
    
    address public warehouseSupplierOrderManagementAddress; // Để nhận hàng từ NCC

    // Tồn kho chính: warehouseAddress => itemId => quantity
    mapping(address => mapping(string => uint256)) public stockLevels;

    // Hàng trả về từ khách hàng tại kho
    mapping(address => mapping(string => uint256)) public returnedStockByCustomer;

    uint256 public nextInternalTransferId = 1; // ID cho việc chuyển hàng nội bộ Kho -> Cửa hàng

    // Sự kiện
        event StockInFromSupplierRecorded(
        address indexed warehouseAddress, // QUAN TRỌNG để lọc theo kho
        string itemId,                    // itemId thường không cần indexed nếu bạn luôn có warehouseAddress
        uint256 quantityAdded,
        uint256 indexed wsOrderId,        // QUAN TRỌNG để liên kết với đơn hàng NCC
        address indexed byWsom            // QUAN TRỌNG để biết ai gọi
    ); // 3 indexed: warehouseAddress, wsOrderId, byWsom

    event StockTransferredToStore(
        address indexed fromWarehouseAddress, // QUAN TRỌNG
        address indexed toStoreAddress,       // QUAN TRỌNG
        string itemId,
        uint256 quantity,
        uint256 indexed internalTransferId,   // QUAN TRỌNG để theo dõi
        address byWarehouseManager            // Người quản lý kho thực hiện, có thể không cần indexed nếu bạn có fromWarehouseAddress
    ); // 3 indexed: fromWarehouseAddress, toStoreAddress, internalTransferId

    event CustomerStockReturnedRecordedToWarehouse(
        address indexed returnToWarehouseAddress, // QUAN TRỌNG
        string itemId,
        uint256 quantityReturned,
        uint256 indexed customerOrderId         // QUAN TRỌNG
        // Không cần thêm indexed ở đây
    ); // 2 indexed: returnToWarehouseAddress, customerOrderId (OK)

    event StockAdjusted(
        address indexed warehouseAddress,        // QUAN TRỌNG
        string indexed itemId,                   // QUAN TRỌNG
        int256 quantityChange,
        string reason,
        address indexed byAdmin                  // QUAN TRỌNG
    ); // 3 indexed: warehouseAddress, itemId, byAdmin (OK)

    event ProcessedReturnedCustomerStockAtWarehouse(
        address indexed warehouseAddress,        // QUAN TRỌNG
        string indexed itemId,                   // QUAN TRỌNG
        uint256 quantityProcessed,
        bool addedToMainStock,
        address indexed byAdmin                  // QUAN TRỌNG
    );
    constructor(address _roleManagementAddress, address _itemsManagementAddress) Ownable() {
        require(_roleManagementAddress != address(0), "WIM: Dia chi RM khong hop le"); // WIM: Địa chỉ RM không hợp lệ
        roleManagementExternal = IRoleManagement(_roleManagementAddress);
        
        if (_itemsManagementAddress != address(0)) {
            itemsManagementExternal = IItemsManagement(_itemsManagementAddress);
        }
    }

    // Modifier chỉ cho phép Quản lý Kho của kho được chỉ định
    modifier onlyWarehouseManager(address _warehouseAddress) {
        // Kiểm tra _warehouseAddress có phải là kho hợp lệ VÀ msg.sender là quản lý của kho đó
        ItemsManagement.PhysicalLocationInfo memory whInfo = itemsManagementExternal.getWarehouseInfo(_warehouseAddress);
        require(whInfo.exists, "WIM: Kho chua duoc dang ky trong ItemsM"); // WIM: Kho chưa được đăng ký trong ItemsM
        require(whInfo.manager == msg.sender, "WIM: Nguoi goi khong phai quan ly kho nay"); // WIM: Người gọi không phải quản lý kho này
        bytes32 wmRole = roleManagementExternal.WAREHOUSE_MANAGER_ROLE();
        require(roleManagementExternal.hasRole(wmRole, msg.sender), "WIM: Nguoi goi thieu vai tro QUAN_LY_KHO"); // WIM: Người gọi thiếu vai trò QUAN_LY_KHO
        _;
    }

    // --- HÀM SETTER (Chỉ Owner) ---
    function setStoreInventoryManagementAddress(address _simAddress) external onlyOwner {
        require(_simAddress != address(0), "WIM: Dia chi SIM khong hop le"); // WIM: Địa chỉ SIM không hợp lệ
        storeInventoryManagementExternal = IStoreInventoryManagement(_simAddress);
    }

    function setWarehouseSupplierOrderManagementAddress(address _wsomAddress) external onlyOwner {
        require(_wsomAddress != address(0), "WIM: Dia chi WSOM khong hop le"); // WIM: Địa chỉ WSOM không hợp lệ
        warehouseSupplierOrderManagementAddress = _wsomAddress;
    }

    // --- CÁC HÀM CỐT LÕI ---

    // Được gọi bởi WarehouseSupplierOrderManagement khi có hàng mới từ nhà cung cấp
    function recordStockInFromSupplier(
        address _warehouseAddress,      // Kho nhận hàng
        string calldata _itemId,         // Mặt hàng
        uint256 _quantity,              // Số lượng
        uint256 _wsOrderId              // ID đơn hàng Kho-NCC
    ) external {
        require(msg.sender == warehouseSupplierOrderManagementAddress, "WIM: Nguoi goi khong phai WSOM"); // WIM: Người gọi không phải WSOM
        require(_quantity > 0, "WIM: So luong them vao phai la so duong"); // WIM: Số lượng thêm vào phải là số dương
        // Tùy chọn: Xác thực _warehouseAddress tồn tại thông qua itemsManagementExternal

        stockLevels[_warehouseAddress][_itemId] += _quantity;
        emit StockInFromSupplierRecorded(_warehouseAddress, _itemId, _quantity, _wsOrderId, msg.sender);
    }

    // Được gọi bởi StoreInventoryManagement (thay mặt Quản lý Cửa hàng) để yêu cầu hàng
    // Logic này giả định StoreInventoryManagement đã xác thực Quản lý Cửa hàng và kho nguồn chỉ định.
    function requestStockTransferToStore(
        address _requestingStoreManager, // Người quản lý cửa hàng yêu cầu (được SIM xác thực)
        address _storeAddress,          // Cửa hàng yêu cầu
        address _warehouseAddress,      // Kho nguồn được chỉ định cho cửa hàng
        string calldata _itemId,         // Mặt hàng
        uint256 _quantity               // Số lượng
    ) external returns (uint256 internalTransferId) {
        require(msg.sender == address(storeInventoryManagementExternal), "WIM: Nguoi goi khong phai SIM"); // WIM: Người gọi không phải SIM
        require(_quantity > 0, "WIM: So luong chuyen phai la so duong"); // WIM: Số lượng chuyển phải là số dương
        
        ItemsManagement.PhysicalLocationInfo memory whInfo = itemsManagementExternal.getWarehouseInfo(_warehouseAddress);
        require(whInfo.exists, "WIM: Kho nguon chua duoc dang ky"); // WIM: Kho nguồn chưa được đăng ký
        // Quản lý thực tế của _warehouseAddress có thể cần phê duyệt.
        // Hiện tại, giả định nếu SIM gọi thì được phép nếu có đủ hàng.

        uint256 currentStock = stockLevels[_warehouseAddress][_itemId];
        require(currentStock >= _quantity, "WIM: Khong du hang trong kho"); // WIM: Không đủ hàng trong kho
        
        stockLevels[_warehouseAddress][_itemId] = currentStock - _quantity;
        internalTransferId = nextInternalTransferId++;

        // Thông báo cho StoreInventoryManagement để xác nhận đã nhận hàng
        storeInventoryManagementExternal.confirmStockReceivedFromWarehouse(
            _storeAddress,
            _itemId,
            _quantity,
            _warehouseAddress, // Báo cáo kho nào đã hoàn thành
            internalTransferId
        );

        emit StockTransferredToStore(_warehouseAddress, _storeAddress, _itemId, _quantity, internalTransferId, _requestingStoreManager); // _requestingStoreManager là người khởi tạo
        return internalTransferId;
    }
    
    // Được gọi bởi CustomerOrderManagement khi khách hàng trả hàng về kho
    function recordReturnedStockByCustomer(
        address _returnToWarehouseAddress, // Kho cụ thể được chỉ định cho việc trả hàng
        string calldata _itemId,
        uint256 _quantity,
        uint256 _customerOrderId
    ) external { // Được gọi bởi COM
        // require(msg.sender == customerOrderManagementAddress, "WIM: Nguoi goi khong phai COM duoc uy quyen"); // Cần địa chỉ COM
        require(_quantity > 0, "WIM: So luong tra ve phai la so duong"); // WIM: Số lượng trả về phải là số dương
        // Tùy chọn: Xác thực _returnToWarehouseAddress qua itemsManagementExternal

        returnedStockByCustomer[_returnToWarehouseAddress][_itemId] += _quantity;
        emit CustomerStockReturnedRecordedToWarehouse(_returnToWarehouseAddress, _itemId, _quantity, _customerOrderId);
    }

    // --- CÁC HÀM ADMIN (Chỉ Owner) ---
    function adjustStockManually(
        address _warehouseAddress,
        string calldata _itemId,
        int256 _quantityChange,      // Có thể âm hoặc dương
        string calldata _reason
    ) external onlyOwner { // Hoặc onlyWarehouseManager(_warehouseAddress)
        uint256 currentStock = stockLevels[_warehouseAddress][_itemId];
        if (_quantityChange > 0) {
            stockLevels[_warehouseAddress][_itemId] = currentStock + uint256(_quantityChange);
        } else if (_quantityChange < 0) {
            uint256 amountToDecrease = uint256(-_quantityChange);
            require(currentStock >= amountToDecrease, "WIM: Dieu chinh thu cong dan den ton kho am"); // WIM: Điều chỉnh thủ công dẫn đến tồn kho âm
            stockLevels[_warehouseAddress][_itemId] = currentStock - amountToDecrease;
        } else {
            revert("WIM: Thay doi so luong khong the bang khong"); // WIM: Thay đổi số lượng không thể bằng không
        }
        emit StockAdjusted(_warehouseAddress, _itemId, _quantityChange, _reason, msg.sender);
    }

    function processCustomerReturnedStock(
        address _warehouseAddress,      // Kho chứa hàng trả về
        string calldata _itemId,
        uint256 _quantityToProcess,
        bool _addToMainStock          // Ví dụ: nếu mặt hàng có thể bán lại
    ) external onlyOwner { // Hoặc onlyWarehouseManager(_warehouseAddress)
        require(_quantityToProcess > 0, "WIM: So luong xu ly phai la so duong"); // WIM: Số lượng xử lý phải là số dương
        uint256 currentReturnedStock = returnedStockByCustomer[_warehouseAddress][_itemId];
        require(currentReturnedStock >= _quantityToProcess, "WIM: Khong du hang tra ve de xu ly"); // WIM: Không đủ hàng trả về để xử lý

        returnedStockByCustomer[_warehouseAddress][_itemId] = currentReturnedStock - _quantityToProcess;
        if (_addToMainStock) {
            stockLevels[_warehouseAddress][_itemId] += _quantityToProcess;
        }
        emit ProcessedReturnedCustomerStockAtWarehouse(_warehouseAddress, _itemId, _quantityToProcess, _addToMainStock, msg.sender);
    }

    // --- CÁC HÀM XEM (VIEW FUNCTIONS) ---
    function getWarehouseStockLevel(address _warehouseAddress, string calldata _itemId) external view returns (uint256) {
        return stockLevels[_warehouseAddress][_itemId];
    }

    function getCustomerReturnedStockLevelAtWarehouse(address _warehouseAddress, string calldata _itemId) external view returns (uint256) {
        return returnedStockByCustomer[_warehouseAddress][_itemId];
    }
}
