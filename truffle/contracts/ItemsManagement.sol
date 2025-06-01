// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";

// Interface để tương tác với hợp đồng RoleManagement
interface IRoleManagement {
    function STORE_DIRECTOR_ROLE() external view returns (bytes32);
    function WAREHOUSE_DIRECTOR_ROLE() external view returns (bytes32);
    function STORE_MANAGER_ROLE() external view returns (bytes32);
    function WAREHOUSE_MANAGER_ROLE() external view returns (bytes32);
    function BOARD_ROLE() external view returns (bytes32);
    function SUPPLIER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getSharesPercentage(address account) external view returns (uint256);
}

contract ItemsManagement is AccessControl {
    IRoleManagement public roleManagementExternal;

    struct ItemInfo {
        string itemId;
        string name;
        string description;
        string category;
        bool exists;
        bool isApprovedByBoard;
        address proposer; // Thành viên BĐH đề xuất
        uint256 referencePriceCeiling; // Giá trần tham khảo do BĐH đặt
    }

    struct PhysicalLocationInfo {
        address locationId;
        string name;
        string locationType; // "STORE" hoặc "WAREHOUSE"
        address manager;      // Quản lý (Store Manager / Warehouse Manager) được gán bởi Director
        bool exists;
        bool isApprovedByBoard; // Được duyệt bởi BĐH
        address designatedSourceWarehouseAddress; // Kho nguồn cho cửa hàng
    }

    struct SupplierInfo {
        address supplierId;
        string name;
        bool isApprovedByBoard; // Được duyệt bởi BĐH
        bool exists;
    }

    struct SupplierItemListing {
        string itemId;
        address supplierAddress;
        uint256 price;
        bool isApprovedByBoard; // Duyệt tự động hoặc thủ công bởi BĐH
        bool exists;
    }

    mapping(string => ItemInfo) public items;
    mapping(address => PhysicalLocationInfo) public physicalLocations;
    mapping(address => SupplierInfo) public suppliers;
    mapping(address => mapping(string => SupplierItemListing)) public supplierItemListings;
    mapping(address => mapping(string => uint256)) public storeItemRetailPrices;

    string[] public itemIds;
    address[] public locationAddresses;
    address[] public supplierAddresses;

    event ItemProposed(string indexed itemId, string name, address indexed proposer);
    event ItemApprovedByBoard(string indexed itemId, uint256 referencePriceCeiling, address indexed finalApprover);
    event PhysicalLocationProposed(address indexed locationId, string name, string locationType, address indexed proposer);
    event PhysicalLocationApprovedByBoard(address indexed locationId, address indexed finalApprover);
    event SupplierProposed(address indexed supplierId, string name, address indexed proposer);
    event SupplierApprovedByBoard(address indexed supplierId, address indexed finalApprover);
    event PhysicalLocationManagerAssigned(address indexed locationId, address newManager, address indexed byDirector);
    event StoreDesignatedSourceWarehouseSet(address indexed storeAddress, address indexed designatedWarehouse, address indexed byStoreDirector);
    event SupplierItemListed(address indexed supplierAddress, string indexed itemId, uint256 price, bool autoApproved);
    event SupplierItemManuallyApprovedByBoard(address indexed supplierAddress, string indexed itemId, address indexed approver);
    event RetailPriceSet(address indexed storeAddress, string indexed itemId, uint256 price, address indexed byStoreDirector);

    constructor(address _roleManagementExternalAddress) {
        require(_roleManagementExternalAddress != address(0), "ItemsM: Dia chi RM Ngoai khong hop le");
        roleManagementExternal = IRoleManagement(_roleManagementExternalAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyBoardMember() {
        require(roleManagementExternal.hasRole(roleManagementExternal.BOARD_ROLE(), msg.sender), "ItemsM: Nguoi goi khong phai Thanh vien BDH");
        _;
    }

    modifier onlySupplier() {
        require(roleManagementExternal.hasRole(roleManagementExternal.SUPPLIER_ROLE(), msg.sender), "ItemsM: Nguoi goi khong phai NCC (RM Ngoai)");
        require(suppliers[msg.sender].exists && suppliers[msg.sender].isApprovedByBoard, "ItemsM: NCC chua duoc dang ky hoac phe duyet");
        _;
    }

    modifier onlyStoreDirector() {
        bytes32 sdRole = roleManagementExternal.STORE_DIRECTOR_ROLE();
        require(roleManagementExternal.hasRole(sdRole, msg.sender), "ItemsM: Nguoi goi thieu vai tro GIAM_DOC_CH (RM Ngoai)");
        _;
    }

    modifier onlyWarehouseDirector() {
        bytes32 wdRole = roleManagementExternal.WAREHOUSE_DIRECTOR_ROLE();
        require(roleManagementExternal.hasRole(wdRole, msg.sender), "ItemsM: Nguoi goi thieu vai tro GIAM_DOC_KHO (RM Ngoai)");
        _;
    }
    
    modifier onlyStoreManagerOfThisStore(address _storeAddress) {
        PhysicalLocationInfo memory storeInfo = physicalLocations[_storeAddress];
        require(storeInfo.exists && keccak256(abi.encodePacked(storeInfo.locationType)) == keccak256(abi.encodePacked("STORE")), "ItemsM: Khong phai cua hang hop le");
        require(storeInfo.manager == msg.sender, "ItemsM: Nguoi goi khong phai quan ly cua hang nay");
        _;
    }

    // SỬA LỖI Ở ĐÂY: Sử dụng Cách 1 (mảng memory để kiểm tra trùng lặp)
    function _getBoardApproval(address[] memory _approvers) internal view returns (bool) {
        if (_approvers.length == 0) return false;
        uint256 totalApprovalShares = 0;
        
        address[] memory processedApprovers = new address[](_approvers.length);
        uint processedCount = 0;

        for (uint i = 0; i < _approvers.length; i++) {
            address approver = _approvers[i];
            
            require(approver != msg.sender, "ItemsM: Nguoi de xuat khong the tu phe duyet");
            require(roleManagementExternal.hasRole(roleManagementExternal.BOARD_ROLE(), approver), "ItemsM: Nguoi phe duyet khong phai thanh vien BDH");

            bool alreadyProcessed = false;
            for (uint j = 0; j < processedCount; j++) {
                if (processedApprovers[j] == approver) {
                    alreadyProcessed = true;
                    break;
                }
            }
            require(!alreadyProcessed, "ItemsM: Nguoi phe duyet bi trung lap");
            
            totalApprovalShares += roleManagementExternal.getSharesPercentage(approver);
            
            processedApprovers[processedCount] = approver;
            processedCount++;
        }
        return totalApprovalShares > 5000;
    }

    // --- QUẢN LÝ MẶT HÀNG BỞI BAN ĐIỀU HÀNH ---
    function proposeNewItem(string calldata _itemId, string calldata _name, string calldata _description, string calldata _category) external onlyBoardMember {
        require(!items[_itemId].exists, "ItemsM: ID mat hang da ton tai");
        require(bytes(_itemId).length > 0, "ItemsM: ID mat hang khong duoc rong");
        items[_itemId] = ItemInfo({itemId: _itemId, name: _name, description: _description, category: _category, exists: true, isApprovedByBoard: false, proposer: msg.sender, referencePriceCeiling: 0});
        if (!_itemExistsInArray(_itemId)) { itemIds.push(_itemId); }
        emit ItemProposed(_itemId, _name, msg.sender);
    }

    function approveProposedItem(string calldata _itemId, uint256 _referencePriceCeiling, address[] calldata _approvers) external onlyBoardMember {
        ItemInfo storage item = items[_itemId];
        require(item.exists, "ItemsM: Mat hang khong ton tai de phe duyet");
        require(!item.isApprovedByBoard, "ItemsM: Mat hang da duoc phe duyet roi");
        require(_referencePriceCeiling > 0, "ItemsM: Gia tran tham khao phai lon hon 0");
        require(_getBoardApproval(_approvers), "ItemsM: Khong du ty le co phan BDH phe duyet");
        item.isApprovedByBoard = true;
        item.referencePriceCeiling = _referencePriceCeiling;
        emit ItemApprovedByBoard(_itemId, _referencePriceCeiling, msg.sender);
    }
    
    // --- QUẢN LÝ ĐỊA ĐIỂM BỞI BAN ĐIỀU HÀNH ---
    function proposeNewPhysicalLocation(address _locationId, string calldata _name, string calldata _locationType) external onlyBoardMember {
        require(!physicalLocations[_locationId].exists, "ItemsM: ID dia diem da ton tai");
        require(_locationId != address(0), "ItemsM: Dia chi dia diem khong hop le");
        bytes32 typeHash = keccak256(abi.encodePacked(_locationType));
        require(typeHash == keccak256(abi.encodePacked("STORE")) || typeHash == keccak256(abi.encodePacked("WAREHOUSE")), "ItemsM: Loai dia diem khong hop le");
        physicalLocations[_locationId] = PhysicalLocationInfo({ locationId: _locationId, name: _name, locationType: _locationType, manager: address(0), exists: true, isApprovedByBoard: false, designatedSourceWarehouseAddress: address(0) });
        if (!_locationExistsInArray(_locationId)) { locationAddresses.push(_locationId); }
        emit PhysicalLocationProposed(_locationId, _name, _locationType, msg.sender);
    }

    function approveProposedPhysicalLocation(address _locationId, address[] calldata _approvers) external onlyBoardMember {
        PhysicalLocationInfo storage loc = physicalLocations[_locationId];
        require(loc.exists, "ItemsM: Dia diem khong ton tai de phe duyet");
        require(!loc.isApprovedByBoard, "ItemsM: Dia diem da duoc phe duyet roi");
        require(_getBoardApproval(_approvers), "ItemsM: Khong du ty le co phan BDH phe duyet");
        loc.isApprovedByBoard = true;
        emit PhysicalLocationApprovedByBoard(_locationId, msg.sender);
    }

    function assignManagerToLocation(address _locationId, address _managerId) external {
        PhysicalLocationInfo storage loc = physicalLocations[_locationId];
        require(loc.exists && loc.isApprovedByBoard, "ItemsM: Dia diem chua ton tai hoac chua duoc BDH phe duyet");
        require(loc.manager == address(0), "ItemsM: Dia diem da co quan ly");
        bytes32 expectedManagerRole; 
        bool callerIsAuthorized = false;
        if (keccak256(abi.encodePacked(loc.locationType)) == keccak256(abi.encodePacked("STORE"))) {
            expectedManagerRole = roleManagementExternal.STORE_MANAGER_ROLE();
            if (roleManagementExternal.hasRole(roleManagementExternal.STORE_DIRECTOR_ROLE(), msg.sender)) {
                callerIsAuthorized = true;
            }
        } else { 
            expectedManagerRole = roleManagementExternal.WAREHOUSE_MANAGER_ROLE();
            if (roleManagementExternal.hasRole(roleManagementExternal.WAREHOUSE_DIRECTOR_ROLE(), msg.sender)) {
                callerIsAuthorized = true;
            }
        }
        require(callerIsAuthorized, "ItemsM: Nguoi goi khong co quyen gan quan ly cho loai dia diem nay");
        require(roleManagementExternal.hasRole(expectedManagerRole, _managerId), "ItemsM: Nguoi duoc gan lam quan ly thieu vai tro phu hop");
        loc.manager = _managerId;
        emit PhysicalLocationManagerAssigned(_locationId, _managerId, msg.sender);
    }

    function setDesignatedSourceWarehouseForStore(address _storeAddress, address _warehouseAddress) external onlyStoreDirector {
        PhysicalLocationInfo storage storeInfo = physicalLocations[_storeAddress];
        require(storeInfo.exists && storeInfo.isApprovedByBoard && keccak256(abi.encodePacked(storeInfo.locationType)) == keccak256(abi.encodePacked("STORE")), "ItemsM: Cua hang khong ton tai, chua duoc BDH phe duyet, hoac khong phai la cua hang");
        if (_warehouseAddress != address(0)) {
            PhysicalLocationInfo memory warehouseInfo = physicalLocations[_warehouseAddress];
            require(warehouseInfo.exists && warehouseInfo.isApprovedByBoard && keccak256(abi.encodePacked(warehouseInfo.locationType)) == keccak256(abi.encodePacked("WAREHOUSE")), "ItemsM: Kho nguon chi dinh khong hop le, chua duoc BDH phe duyet, hoac khong phai la kho");
        }
        storeInfo.designatedSourceWarehouseAddress = _warehouseAddress;
        emit StoreDesignatedSourceWarehouseSet(_storeAddress, _warehouseAddress, msg.sender);
    }

    function proposeNewSupplier(address _supplierId, string calldata _name) external onlyBoardMember {
        require(!suppliers[_supplierId].exists, "ItemsM: ID NCC da ton tai");
        require(_supplierId != address(0), "ItemsM: Dia chi NCC khong hop le");
        suppliers[_supplierId] = SupplierInfo({ supplierId: _supplierId, name: _name, isApprovedByBoard: false, exists: true });
        if(!_supplierExistsInArray(_supplierId)){ supplierAddresses.push(_supplierId); }
        emit SupplierProposed(_supplierId, _name, msg.sender);
    }
    
    function approveProposedSupplier(address _supplierId, address[] calldata _approvers) external onlyBoardMember {
        SupplierInfo storage sup = suppliers[_supplierId];
        require(sup.exists, "ItemsM: NCC khong ton tai de phe duyet");
        require(!sup.isApprovedByBoard, "ItemsM: NCC da duoc phe duyet roi");
        require(_getBoardApproval(_approvers), "ItemsM: Khong du ty le co phan BDH phe duyet");
        sup.isApprovedByBoard = true;
        emit SupplierApprovedByBoard(_supplierId, msg.sender);
    }

    function listSupplierItem(string calldata _itemId, uint256 _price) external onlySupplier {
        ItemInfo memory itemInfo = items[_itemId];
        require(itemInfo.exists && itemInfo.isApprovedByBoard, "ItemsM: Mat hang khong ton tai hoac chua duoc BDH phe duyet chung");
        require(!supplierItemListings[msg.sender][_itemId].exists, "ItemsM: Mat hang cua NCC da duoc niem yet");
        require(_price > 0, "ItemsM: Gia phai la so duong");
        bool autoApproved = (_price <= itemInfo.referencePriceCeiling && itemInfo.referencePriceCeiling > 0);
        supplierItemListings[msg.sender][_itemId] = SupplierItemListing({ itemId: _itemId, supplierAddress: msg.sender, price: _price, isApprovedByBoard: autoApproved, exists: true });
        emit SupplierItemListed(msg.sender, _itemId, _price, autoApproved);
    }

    function approveSupplierItemManuallyByBoard(address _supplierAddress, string calldata _itemId, address[] calldata _approvers) external onlyBoardMember {
        require(suppliers[_supplierAddress].exists && suppliers[_supplierAddress].isApprovedByBoard, "ItemsM: NCC khong ton tai hoac chua duoc BDH phe duyet");
        SupplierItemListing storage listing = supplierItemListings[_supplierAddress][_itemId];
        require(listing.exists, "ItemsM: Mat hang cua NCC chua duoc niem yet");
        require(!listing.isApprovedByBoard, "ItemsM: Mat hang nay cua NCC da duoc phe duyet roi");
        require(_getBoardApproval(_approvers), "ItemsM: Khong du ty le co phan BDH phe duyet cho mat hang NCC nay");
        listing.isApprovedByBoard = true;
        emit SupplierItemManuallyApprovedByBoard(_supplierAddress, _itemId, msg.sender);
    }

    function setStoreItemRetailPrice(address _storeAddress, string calldata _itemId, uint256 _price) external onlyStoreDirector {
        require(items[_itemId].exists && items[_itemId].isApprovedByBoard, "ItemsM: Mat hang khong ton tai hoac chua duoc BDH phe duyet");
        PhysicalLocationInfo memory storeInfo = physicalLocations[_storeAddress];
        require(storeInfo.exists && storeInfo.isApprovedByBoard && keccak256(abi.encodePacked(storeInfo.locationType)) == keccak256(abi.encodePacked("STORE")), "ItemsM: Cua hang khong ton tai, chua duoc BDH phe duyet, hoac khong phai la cua hang");
        require(_price > 0, "ItemsM: Gia le phai la so duong");
        storeItemRetailPrices[_storeAddress][_itemId] = _price;
        emit RetailPriceSet(_storeAddress, _itemId, _price, msg.sender);
    }

    function _itemExistsInArray(string calldata _itemId) internal view returns (bool) {
        for (uint i = 0; i < itemIds.length; i++) {
            if (keccak256(abi.encodePacked(itemIds[i])) == keccak256(abi.encodePacked(_itemId))) return true;
        }
        return false;
    }
    function _locationExistsInArray(address _locationId) internal view returns (bool) {
        for (uint i = 0; i < locationAddresses.length; i++) {
            if (locationAddresses[i] == _locationId) return true;
        }
        return false;
    }
     function _supplierExistsInArray(address _supplierId) internal view returns (bool) {
        for (uint i = 0; i < supplierAddresses.length; i++) {
            if (supplierAddresses[i] == _supplierId) return true;
        }
        return false;
    }

    function getItemInfo(string calldata _itemId) external view returns (ItemInfo memory) { return items[_itemId]; }
    function getPhysicalLocationInfo(address _locationId) external view returns (PhysicalLocationInfo memory) { return physicalLocations[_locationId]; }
    function getStoreInfo(address _storeAddress) external view returns (PhysicalLocationInfo memory) {
        PhysicalLocationInfo memory loc = physicalLocations[_storeAddress];
        require(loc.exists && keccak256(abi.encodePacked(loc.locationType)) == keccak256(abi.encodePacked("STORE")), "ItemsM: Khong phai la cua hang");
        return loc;
    }
    function getWarehouseInfo(address _warehouseAddress) external view returns (PhysicalLocationInfo memory) {
        PhysicalLocationInfo memory loc = physicalLocations[_warehouseAddress];
        require(loc.exists && keccak256(abi.encodePacked(loc.locationType)) == keccak256(abi.encodePacked("WAREHOUSE")), "ItemsM: Khong phai la kho");
        return loc;
    }
    function getSupplierInfo(address _supplierId) external view returns (SupplierInfo memory) { return suppliers[_supplierId]; }
    function getSupplierItemDetails(address _supplierAddress, string calldata _itemId) external view returns (SupplierItemListing memory) { return supplierItemListings[_supplierAddress][_itemId]; }
    function getItemRetailPriceAtStore(string calldata _itemId, address _storeAddress) external view returns (uint256 price, bool priceExists) {
        price = storeItemRetailPrices[_storeAddress][_itemId];
        return (price, price > 0);
    }
    function getAllItemIds() external view returns (string[] memory) { return itemIds; }
    function getAllLocationAddresses() external view returns (address[] memory) { return locationAddresses; }
    function getAllSupplierAddresses() external view returns (address[] memory) { return supplierAddresses; }
}