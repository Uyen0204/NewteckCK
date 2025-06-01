// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0; 

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; // Đã sửa đường dẫn import

// --- INTERFACES ---
// Khai báo trước cấu trúc từ ItemsManagement (nếu bạn dùng struct trực tiếp trong interface)
// Nếu không, chỉ cần khai báo interface là đủ.
contract ItemsManagement { 
    struct PhysicalLocationInfo { address locationId; string name; string locationType; address manager; bool exists; address designatedSourceWarehouseAddress; }
    struct SupplierInfo { address supplierId; string name; bool isApprovedByBoard; bool exists;}
}

// Interface cho RoleManagement 
interface IRoleManagementMinimal { // Interface tối thiểu RoleManagement mà CTM cần
    function FINANCE_DIRECTOR_ROLE() external view returns (bytes32);
    function WAREHOUSE_MANAGER_ROLE() external view returns (bytes32); // Giữ lại nếu còn dùng cho logic top-up
    function hasRole(bytes32 role, address account) external view returns (bool);
}

// Interface MỚI để CTM tương tác với RoleManagement cho việc kích hoạt BĐH
interface IRoleManagementForBoardActivation {
    function activateBoardMemberByTreasury(address candidate, uint256 contributedAmount) external;
    function getProposedShareCapital(address candidate) external view returns (uint256);
}

// Interface cho ItemsManagement
interface IItemsManagementMinimal { // Interface tối thiểu ItemsManagement mà CTM cần
    function getWarehouseInfo(address warehouseAddress) external view returns (ItemsManagement.PhysicalLocationInfo memory);
    function getSupplierInfo(address supplierAddress) external view returns (ItemsManagement.SupplierInfo memory);
}
// --- END INTERFACES ---


// Hợp đồng Quản lý Ngân quỹ Công ty
contract CompanyTreasuryManager is Ownable, ReentrancyGuard {
    IRoleManagementMinimal public immutable roleManagement;    // Dùng interface tối thiểu
    IItemsManagementMinimal public immutable itemsManagement; // Dùng interface tối thiểu
    
    address public roleManagementFullAddress; // Địa chỉ đầy đủ của RoleManagement cho việc kích hoạt BĐH và các chức năng khác nếu cần
    address public warehouseSupplierOrderManagement;
    address public customerOrderManagementAddress; 

    address public financeDirector; 

    uint256 public constant INTERNAL_ROLE_TOP_UP_THRESHOLD = 20 ether;
    uint256 public constant INTERNAL_ROLE_TOP_UP_AMOUNT = 5 ether;
    mapping(address => mapping(address => uint256)) public warehouseSpendingPolicies; 
    mapping(address => uint256) public warehouseSpendingThisPeriod; 
    uint256 public constant WAREHOUSE_SPENDING_LIMIT_PER_PERIOD = 100 ether;
    struct EscrowDetails { address warehouseAddress; address supplierAddress; uint256 amount; bool active; }
    mapping(string => EscrowDetails) public activeEscrows;

    // Sự kiện
    event FundsDeposited(address indexed from, uint256 amount);
    event InitialCapitalReceived(uint256 amount); // Vốn ban đầu khi deploy CTM
    event BoardMemberContributionReceived(address indexed candidate, uint256 amount); // Khi ứng viên BĐH góp vốn
    event InternalTransfer(address indexed by, address indexed toRoleHolder, uint256 amount);
    event SupplierPaymentEscrowed(string internalOrderId, address indexed warehouse, address indexed supplier, uint256 amount);
    event SupplierPaymentReleased(string internalOrderId, address indexed supplier, uint256 amount);
    event EscrowRefunded(string internalOrderId, address indexed warehouse, uint256 amount);
    event SpendingPolicySet(address indexed setBy, address indexed warehouse, address indexed supplier, uint256 maxAmount);
    event FinanceDirectorSet(address indexed newDirector);
    event RoleManagementFullAddressSet(address indexed rmFullAddress);
    event WarehouseSupplierOrderManagementAddressSet(address indexed wsomAddress);
    event CustomerOrderManagementAddressSet(address indexed comAddress);
    event GeneralWithdrawal(address indexed by, address indexed recipient, uint256 amount, string reason);
    event CustomerRefundProcessedFromTreasury(uint256 indexed orderId, address indexed customer, uint256 amount);

    modifier onlyFinanceDirector() {
        require(msg.sender == financeDirector, "CTM: Nguoi goi khong phai Giam doc Tai chinh");
        _;
    }

    constructor(
        address _roleManagementAddress,     // Địa chỉ RoleManagement
        address _itemsManagementAddress,
        uint256 _expectedInitialCapital     // Vốn ban đầu khi deploy CTM (ví dụ, từ người deploy tự góp)
    ) Ownable() payable { // Sửa: Ownable() không có tham số
        require(_roleManagementAddress != address(0), "CTM: Dia chi RoleManagement khong hop le");
        require(_itemsManagementAddress != address(0), "CTM: Dia chi ItemsManagement khong hop le");
        require(_expectedInitialCapital >= 0, "CTM: Von ban dau du kien khong the am"); // Cho phép vốn ban đầu là 0

        roleManagementFullAddress = _roleManagementAddress; // Lưu địa chỉ đầy đủ để gọi các hàm trong IRoleManagementForBoardActivation

        if (_expectedInitialCapital > 0) {
            require(msg.value == _expectedInitialCapital, "CTM: So von ban dau gui khong chinh xac");
            emit InitialCapitalReceived(msg.value);
        } else {
            // Nếu vốn ban đầu dự kiến là 0, không nên gửi Ether kèm theo
            require(msg.value == 0, "CTM: Khong nen gui Ether neu von ban dau du kien la 0");
        }
    }

    function setWarehouseSupplierOrderManagementAddress(address _wsomAddress) external onlyOwner {
        require(_wsomAddress != address(0), "CTM: Dia chi WSOM khong hop le");
        warehouseSupplierOrderManagement = _wsomAddress;
        emit WarehouseSupplierOrderManagementAddressSet(_wsomAddress);
    }

    function setCustomerOrderManagementAddress(address _comAddress) external onlyOwner {
        require(_comAddress != address(0), "CTM: Dia chi COM khong hop le");
        customerOrderManagementAddress = _comAddress;
        emit CustomerOrderManagementAddressSet(_comAddress);
    }

    function setInitialFinanceDirector(address _director) external onlyOwner {
        require(_director != address(0), "CTM: Dia chi Giam doc khong the la zero");
        bytes32 finDirectorRole = roleManagement.FINANCE_DIRECTOR_ROLE(); 
        require(roleManagement.hasRole(finDirectorRole, _director), "CTM: Dia chi duoc gan thieu vai tro FIN_DIRECTOR_ROLE");
        financeDirector = _director;
        emit FinanceDirectorSet(_director);
    }

    receive() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }

    function transferToInternalRole(address _roleHolderAddress, bytes32 _roleKey)
        external
        onlyFinanceDirector
        nonReentrant
    {
        require(_roleHolderAddress != address(0), "CTM: Dia chi nguoi giu vai tro khong the la zero");
        require(roleManagement.hasRole(_roleKey, _roleHolderAddress), "CTM: Dia chi muc tieu khong co vai tro duoc chi dinh");
        bytes32 finDirectorRole = roleManagement.FINANCE_DIRECTOR_ROLE();
        require(_roleKey != finDirectorRole, "CTM: Khong the nap tien cho vai tro Giam doc Tai chinh theo cach nay");

        uint256 targetBalance = _roleHolderAddress.balance;
        require(targetBalance < INTERNAL_ROLE_TOP_UP_THRESHOLD, "CTM: So du cua nguoi giu vai tro muc tieu khong duoi nguong");
        uint256 amountToSend = INTERNAL_ROLE_TOP_UP_AMOUNT;
        require(address(this).balance >= amountToSend, "CTM: Ngan quy khong du tien");

        (bool success, ) = payable(_roleHolderAddress).call{value: amountToSend}("");
        require(success, "CTM: Chuyen tien noi bo that bai");
        emit InternalTransfer(msg.sender, _roleHolderAddress, amountToSend);
    }

    function setWarehouseSpendingPolicy(
        address _warehouseAddress,
        address _supplierAddress,
        uint256 _maxAmountPerOrder
    ) external onlyFinanceDirector {
        require(_warehouseAddress != address(0), "CTM: Dia chi kho khong the la zero");
        require(_supplierAddress != address(0), "CTM: Dia chi NCC khong the la zero");

        ItemsManagement.PhysicalLocationInfo memory whInfo = itemsManagement.getWarehouseInfo(_warehouseAddress);
        require(whInfo.exists, "CTM: Kho khong ton tai trong IM");
        ItemsManagement.SupplierInfo memory supInfo = itemsManagement.getSupplierInfo(_supplierAddress);
        require(supInfo.exists, "CTM: NCC khong ton tai trong IM");

        warehouseSpendingPolicies[_warehouseAddress][_supplierAddress] = _maxAmountPerOrder;
        emit SpendingPolicySet(msg.sender, _warehouseAddress, _supplierAddress, _maxAmountPerOrder);
    }

    function generalWithdrawal(address payable _recipient, uint256 _amount, string calldata _reason)
        external
        onlyFinanceDirector
        nonReentrant
    {
        require(_recipient != address(0), "CTM: Nguoi nhan khong the la dia chi zero");
        require(_amount > 0, "CTM: So tien phai la so duong");
        require(address(this).balance >= _amount, "CTM: Ngan quy khong du tien");

        (bool success, ) = _recipient.call{value: _amount}("");
        require(success, "CTM: Rut tien chung that bai");
        emit GeneralWithdrawal(msg.sender, _recipient, _amount, _reason);
    }

    function changeFinanceDirector(address _newDirector) external onlyOwner {
        require(_newDirector != address(0), "CTM: Giam doc moi khong the la dia chi zero");
        bytes32 finDirectorRole = roleManagement.FINANCE_DIRECTOR_ROLE();
        require(roleManagement.hasRole(finDirectorRole, _newDirector), "CTM: Giam doc moi thieu vai tro FIN_DIRECTOR_ROLE");
        require(_newDirector != financeDirector, "CTM: Giam doc moi trung voi giam doc hien tai");
        financeDirector = _newDirector;
        emit FinanceDirectorSet(_newDirector);
    }

    function requestEscrowForSupplierOrder(
        address _warehouseAddress,
        address _supplierAddress,
        string calldata _internalSupplierOrderId,
        uint256 _amount
    ) external nonReentrant returns (bool) {
        require(msg.sender == warehouseSupplierOrderManagement, "CTM: Nguoi goi khong phai WSOM");
        require(_warehouseAddress != address(0), "CTM: Dia chi kho ky quy khong the la zero");
        require(_supplierAddress != address(0), "CTM: Dia chi NCC ky quy khong the la zero");
        require(bytes(_internalSupplierOrderId).length > 0, "CTM: ID don hang ky quy khong duoc rong");
        require(_amount > 0, "CTM: So tien ky quy phai la so duong");
        require(!activeEscrows[_internalSupplierOrderId].active, "CTM: ID ky quy da kich hoat hoac khong hop le");

        uint256 maxAmountAllowed = warehouseSpendingPolicies[_warehouseAddress][_supplierAddress];
        require(maxAmountAllowed > 0, "CTM: Khong co chinh sach chi tieu cho kho/ncc nay");
        require(_amount <= maxAmountAllowed, "CTM: So tien vuot qua gioi han chinh sach moi don hang");

        uint256 spendingAfterThisOrder = warehouseSpendingThisPeriod[_warehouseAddress] + _amount;
        require(spendingAfterThisOrder <= WAREHOUSE_SPENDING_LIMIT_PER_PERIOD, "CTM: Vuot qua gioi han chi tieu dinh ky cua kho");
        require(address(this).balance >= _amount, "CTM: Ngan quy khong du tien de ky quy");

        activeEscrows[_internalSupplierOrderId] = EscrowDetails({
            warehouseAddress: _warehouseAddress, supplierAddress: _supplierAddress, amount: _amount, active: true
        });
        warehouseSpendingThisPeriod[_warehouseAddress] = spendingAfterThisOrder;
        emit SupplierPaymentEscrowed(_internalSupplierOrderId, _warehouseAddress, _supplierAddress, _amount);
        return true;
    }

    function releaseEscrowToSupplier(
        address _supplierAddressToVerify,
        string calldata _internalSupplierOrderId,
        uint256 _amountToVerify
    ) external nonReentrant returns (bool) {
        require(msg.sender == warehouseSupplierOrderManagement, "CTM: Nguoi goi khong phai WSOM");
        require(_supplierAddressToVerify != address(0), "CTM: Dia chi NCC khong the la zero de giai ngan");
        require(bytes(_internalSupplierOrderId).length > 0, "CTM: ID don hang khong duoc rong de giai ngan");

        EscrowDetails storage escrow = activeEscrows[_internalSupplierOrderId];
        require(escrow.active, "CTM: Ky quy khong kich hoat hoac khong tim thay de giai ngan");
        require(escrow.supplierAddress == _supplierAddressToVerify, "CTM: NCC khong khop de giai ngan");
        require(escrow.amount == _amountToVerify, "CTM: So tien khong khop de giai ngan");

        escrow.active = false;
        (bool success, ) = payable(escrow.supplierAddress).call{value: escrow.amount}("");
        if (!success) {
            escrow.active = true; 
            return false;
        }
        emit SupplierPaymentReleased(_internalSupplierOrderId, escrow.supplierAddress, escrow.amount);
        return true;
    }

    function refundEscrowToTreasury(
        address _warehouseAddressToVerify,
        string calldata _internalSupplierOrderId,
        uint256 _amountToVerify
    ) external nonReentrant returns (bool) {
        require(msg.sender == warehouseSupplierOrderManagement, "CTM: Nguoi goi khong phai WSOM");
        require(_warehouseAddressToVerify != address(0), "CTM: Dia chi kho khong the la zero de hoan tra");
        require(bytes(_internalSupplierOrderId).length > 0, "CTM: ID don hang khong duoc rong de hoan tra");

        EscrowDetails storage escrow = activeEscrows[_internalSupplierOrderId];
        require(escrow.active, "CTM: Ky quy khong kich hoat hoac khong tim thay de hoan tra");
        require(escrow.warehouseAddress == _warehouseAddressToVerify, "CTM: Kho khong khop de hoan tra");
        require(escrow.amount == _amountToVerify, "CTM: So tien khong khop de hoan tra");

        escrow.active = false;
        warehouseSpendingThisPeriod[escrow.warehouseAddress] -= escrow.amount;
        emit EscrowRefunded(_internalSupplierOrderId, escrow.warehouseAddress, escrow.amount);
        return true;
    }

    function refundCustomerOrderFromTreasury(
        uint256 _orderId, 
        address payable _customerAddress, 
        uint256 _amountToRefund
    )
        external
        nonReentrant
    {
        require(msg.sender == customerOrderManagementAddress, "CTM: Chi COM moi duoc yeu cau hoan tien nay");
        require(_customerAddress != address(0), "CTM: Dia chi khach hang khong hop le de hoan tien");
        require(_amountToRefund > 0, "CTM: So tien hoan phai lon hon 0");
        require(address(this).balance >= _amountToRefund, "CTM: Ngan quy khong du tien de hoan");

        (bool success, ) = _customerAddress.call{value: _amountToRefund}("");
        require(success, "CTM: Hoan tien cho khach tu ngan quy that bai");

        emit CustomerRefundProcessedFromTreasury(_orderId, _customerAddress, _amountToRefund);
    }

    // Ứng viên BĐH gửi vốn góp vào đây
    function receiveBoardMemberContribution() external payable nonReentrant {
        address candidate = msg.sender;
        uint256 amountContributed = msg.value;

        require(roleManagementFullAddress != address(0), "CTM: Dia chi RoleManagement day du chua duoc thiet lap");
        
        uint256 proposedCapital = IRoleManagementForBoardActivation(roleManagementFullAddress).getProposedShareCapital(candidate);
        
        require(proposedCapital > 0, "CTM: Khong co de xuat von cho ung vien nay hoac RoleManagement chua san sang");
        require(amountContributed == proposedCapital, "CTM: So tien gop khong dung voi de xuat von");

        // msg.value đã tự động được cộng vào số dư của contract này
        emit BoardMemberContributionReceived(candidate, amountContributed);

        // Gọi lại RoleManagement để kích hoạt thành viên
        IRoleManagementForBoardActivation(roleManagementFullAddress).activateBoardMemberByTreasury(candidate, amountContributed);
    }

    function getBalance() external view returns (uint256) { return address(this).balance; }
    function getWarehouseSpendingPolicy(address _warehouseAddress, address _supplierAddress) external view returns (uint256) { return warehouseSpendingPolicies[_warehouseAddress][_supplierAddress]; }
    function getWarehouseSpendingThisPeriod(address _warehouseAddress) external view returns (uint256) { return warehouseSpendingThisPeriod[_warehouseAddress]; }
    function getEscrowDetails(string calldata _internalSupplierOrderId) external view returns (EscrowDetails memory) { return activeEscrows[_internalSupplierOrderId]; }
    function WAREHOUSE_SPENDING_LIMIT_PER_PERIOD_CONST() external pure returns (uint256) { return WAREHOUSE_SPENDING_LIMIT_PER_PERIOD; }
    function INTERNAL_ROLE_TOP_UP_THRESHOLD_CONST() external pure returns (uint256) { return INTERNAL_ROLE_TOP_UP_THRESHOLD; }
    function INTERNAL_ROLE_TOP_UP_AMOUNT_CONST() external pure returns (uint256) { return INTERNAL_ROLE_TOP_UP_AMOUNT; }
}