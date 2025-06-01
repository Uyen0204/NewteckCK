// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract RoleManagement is AccessControl {
    bytes32 public constant BOARD_ROLE = keccak256("BOARD_ROLE");
    bytes32 public constant WAREHOUSE_DIRECTOR_ROLE = keccak256("WAREHOUSE_DIRECTOR_ROLE");
    bytes32 public constant STORE_DIRECTOR_ROLE = keccak256("STORE_DIRECTOR_ROLE");
    bytes32 public constant FINANCE_DIRECTOR_ROLE = keccak256("FINANCE_DIRECTOR_ROLE");
    bytes32 public constant WAREHOUSE_MANAGER_ROLE = keccak256("WAREHOUSE_MANAGER_ROLE");
    bytes32 public constant STORE_MANAGER_ROLE = keccak256("STORE_MANAGER_ROLE");
    bytes32 public constant SUPPLIER_ROLE = keccak256("SUPPLIER_ROLE");

    enum BoardMemberStatus {
        None,               // Chưa có trạng thái
        PendingConfirmation,// Đã được BĐH hiện tại phê duyệt sơ bộ, chờ ứng viên xác nhận và góp vốn
        Active,             // Thành viên BĐH chính thức
        Removed             // Đã bị loại bỏ
    }

    struct BoardMember {
        uint256 shareCapitalProposed;   // Vốn góp được đề xuất/quy ước khi ở trạng thái PendingConfirmation
        uint256 shareCapitalContributed;// Vốn thực tế đã góp khi trở thành Active
        BoardMemberStatus status;       // Trạng thái của thành viên/ứng viên
    }

    mapping(address => BoardMember) public boardMembers;
    address[] public boardAddresses; // Chỉ lưu các thành viên Active
    uint256 public totalCapital;    // Tổng vốn góp của các thành viên Active

    address public companyTreasuryManagerAddress; // Địa chỉ CTM để chỉ CTM mới được gọi hàm kích hoạt

    uint8 public initialMembersAddedCount; // Đếm số thành viên BĐH ban đầu đã được thêm qua cơ chế bootstrap
    uint8 public constant MAX_INITIAL_MEMBERS = 3; // Số lượng thành viên bootstrap tối đa

    event BoardMemberProposed(address indexed candidate, uint256 shareCapitalProposed); // Đề xuất thông thường
    event InitialBoardMemberProposedByAdmin(address indexed candidate, uint256 shareCapitalProposed); // Đề xuất trong giai đoạn bootstrap
    event BoardMemberActivated(address indexed member, uint256 shareCapitalContributed);
    event BoardMemberRemoved(address indexed member);
    event CompanyTreasuryManagerAddressSet(address indexed ctmAddress);


    constructor() {
        // 1. Cấp vai trò Admin cho người deploy
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // 2. Thiết lập người deploy làm thành viên BĐH hoạt động đầu tiên
        address initialBoardMember = msg.sender;
        uint256 initialCapitalContribution = uint256(10 ether); // Ví dụ vốn góp ban đầu của người deploy

        require(initialBoardMember != address(0), "RM: Dia chi nguoi trien khai khong hop le");

        BoardMember storage member = boardMembers[initialBoardMember];
        member.shareCapitalProposed = initialCapitalContribution;
        member.shareCapitalContributed = initialCapitalContribution;
        member.status = BoardMemberStatus.Active;

        boardAddresses.push(initialBoardMember);
        _grantRole(BOARD_ROLE, initialBoardMember);
        totalCapital = initialCapitalContribution;
        initialMembersAddedCount = 1; // Người deploy là người đầu tiên

        emit BoardMemberActivated(initialBoardMember, initialCapitalContribution);
    }
    
    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "RM: Chi Admin duoc phep");
        _;
    }
    
    modifier onlyActiveBoardMember() {
        require(boardMembers[msg.sender].status == BoardMemberStatus.Active && hasRole(BOARD_ROLE, msg.sender), "RM: Chi thanh vien BDH hoat dong duoc phep");
        _;
    }

    modifier onlyCTM() {
        require(msg.sender == companyTreasuryManagerAddress, "RM: Chi CTM moi duoc goi ham nay");
        _;
    }

    function setCompanyTreasuryManagerAddress(address _ctmAddress) external onlyAdmin {
        require(_ctmAddress != address(0), "RM: Dia chi CTM khong hop le");
        companyTreasuryManagerAddress = _ctmAddress;
        emit CompanyTreasuryManagerAddressSet(_ctmAddress);
    }

    function getSharesPercentage(address account) public view returns (uint256) {
        if (boardMembers[account].status != BoardMemberStatus.Active || totalCapital == 0) {
            return 0;
        }
        return (boardMembers[account].shareCapitalContributed * 10000) / totalCapital;
    }

    function _sumSharesPercentage(address[] memory approvers) internal view returns (uint256) {
        uint256 totalPercentageSum = 0;
        for (uint i = 0; i < approvers.length; i++) {
            require(boardMembers[approvers[i]].status == BoardMemberStatus.Active && hasRole(BOARD_ROLE, approvers[i]), "RM: Nguoi phe duyet khong phai thanh vien BDH hoat dong hop le");
            totalPercentageSum += getSharesPercentage(approvers[i]);
        }
        return totalPercentageSum;
    }

    // Bước Bootstrap: Admin thêm các thành viên BĐH ban đầu (tối đa MAX_INITIAL_MEMBERS - 1 người nữa)
    function addInitialBoardMemberByAdmin(address _candidate, uint256 _shareCapitalProposed)
        external
        onlyAdmin 
    {
        require(initialMembersAddedCount < MAX_INITIAL_MEMBERS, "RM: Da dat so luong thanh vien BDH ban dau toi da");
        require(_candidate != address(0), "RM: Dia chi ung vien khong hop le");
        BoardMember storage member = boardMembers[_candidate];
        require(member.status == BoardMemberStatus.None, "RM: Ung vien da ton tai hoac dang trong qua trinh xu ly");
        require(_shareCapitalProposed > 0, "RM: Von gop de xuat phai lon hon 0");

        member.shareCapitalProposed = _shareCapitalProposed;
        member.status = BoardMemberStatus.PendingConfirmation;
        
        initialMembersAddedCount++; 
        emit InitialBoardMemberProposedByAdmin(_candidate, _shareCapitalProposed);
    }

    // Bước Thông thường: BĐH hiện tại đề xuất ứng viên mới (sau giai đoạn bootstrap)
    function proposeBoardMember(address _candidate, uint256 _shareCapitalProposed, address[] memory _approvers)
        external
        onlyActiveBoardMember 
    {
        require(initialMembersAddedCount >= MAX_INITIAL_MEMBERS, "RM: Quy trinh bootstrap chua hoan tat hoac da du thanh vien bootstrap");
        require(_candidate != address(0), "RM: Dia chi ung vien khong hop le");
        BoardMember storage member = boardMembers[_candidate];
        require(member.status == BoardMemberStatus.None, "RM: Ung vien da ton tai hoac dang trong qua trinh xu ly");
        require(_shareCapitalProposed > 0, "RM: Von gop de xuat phai lon hon 0");
        require(_approvers.length > 0, "RM: Can it nhat mot nguoi phe duyet (khac nguoi de xuat)");

        for(uint i = 0; i < _approvers.length; i++) {
            require(_approvers[i] != msg.sender, "RM: Nguoi de xuat khong duoc tu phe duyet trong danh sach approvers");
        }

        uint256 approvalSharesPercent = _sumSharesPercentage(_approvers);
        require(approvalSharesPercent > 5000, "RM: Khong du ty le co phan BDH phe duyet de xuat");

        member.shareCapitalProposed = _shareCapitalProposed;
        member.status = BoardMemberStatus.PendingConfirmation;
        
        emit BoardMemberProposed(_candidate, _shareCapitalProposed);
    }

    // Bước 2 (chung cho cả bootstrap và thông thường): CTM gọi hàm này sau khi nhận được vốn góp
    function activateBoardMemberByTreasury(address _candidate, uint256 _contributedAmount) 
        external 
        onlyCTM 
    {
        BoardMember storage member = boardMembers[_candidate];
        require(member.status == BoardMemberStatus.PendingConfirmation, "RM: Ung vien khong o trang thai cho xac nhan");
        require(_contributedAmount == member.shareCapitalProposed, "RM: So tien CTM bao cao khong khop voi de xuat");

        member.status = BoardMemberStatus.Active;
        member.shareCapitalContributed = _contributedAmount;
        
        bool alreadyInArray = false;
        for(uint i = 0; i < boardAddresses.length; i++){
            if(boardAddresses[i] == _candidate){
                alreadyInArray = true;
                break;
            }
        }
        if(!alreadyInArray){
            boardAddresses.push(_candidate);
        }

        _grantRole(BOARD_ROLE, _candidate);
        totalCapital += _contributedAmount;
        emit BoardMemberActivated(_candidate, _contributedAmount);
    }
    
    // Hàm để CTM đọc số vốn đề xuất của một ứng viên
    function getProposedShareCapital(address _candidate) external view returns (uint256) {
        // Cho phép CTM, Admin, và BĐH hiện tại xem
        require(msg.sender == companyTreasuryManagerAddress || 
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || 
                (boardMembers[msg.sender].status == BoardMemberStatus.Active && hasRole(BOARD_ROLE, msg.sender)), 
                "RM: Khong co quyen truy cap thong tin von de xuat");
        
        if (boardMembers[_candidate].status == BoardMemberStatus.PendingConfirmation) {
            return boardMembers[_candidate].shareCapitalProposed;
        }
        return 0; // Hoặc revert nếu không tìm thấy hoặc trạng thái không đúng
    }

    // Hàm xóa thành viên Ban Giám Đốc
    function removeBoardMember(address _accountToRemove, address[] memory _approvers)
        external
        onlyActiveBoardMember // Người đề xuất xóa phải là BĐH hoạt động
    {
        require(boardMembers[_accountToRemove].status == BoardMemberStatus.Active, "RM: Tai khoan khong phai la thanh vien BDH hoat dong de xoa");
        require(_approvers.length > 0, "RM: Can nguoi phe duyet viec xoa");

        for(uint i = 0; i < _approvers.length; i++) {
            require(_approvers[i] != msg.sender, "RM: Nguoi de xuat xoa khong duoc tu phe duyet");
            require(_approvers[i] != _accountToRemove, "RM: Tai khoan bi xoa khong the phe duyet viec xoa chinh minh");
        }

        uint256 approvalSharesPercent = _sumSharesPercentage(_approvers);
        require(approvalSharesPercent > 5000, "RM: Khong du ty le co phan BDH phe duyet viec xoa");

        totalCapital -= boardMembers[_accountToRemove].shareCapitalContributed;
        _revokeRole(BOARD_ROLE, _accountToRemove);
        boardMembers[_accountToRemove].status = BoardMemberStatus.Removed;
        // boardMembers[_accountToRemove].shareCapitalContributed = 0; // Optional: reset contributed capital

        for (uint i = 0; i < boardAddresses.length; i++) {
            if (boardAddresses[i] == _accountToRemove) {
                boardAddresses[i] = boardAddresses[boardAddresses.length - 1];
                boardAddresses.pop();
                break;
            }
        }
        emit BoardMemberRemoved(_accountToRemove);
    }

    // Các hàm cấp/thu hồi vai trò khác (Director, Supplier) bởi BĐH
    function grantRoleByBoard(bytes32 role, address account, address[] memory approvers) external onlyActiveBoardMember {
        require(
            role == WAREHOUSE_DIRECTOR_ROLE ||
            role == STORE_DIRECTOR_ROLE ||
            role == FINANCE_DIRECTOR_ROLE ||
            role == SUPPLIER_ROLE, "RM: Vai tro khong hop le de BDH cap/thu hoi"
        );
        require(account != address(0), "RM: Tai khoan khong hop le");
        require(approvers.length > 0, "RM: Can nguoi phe duyet");
         for(uint i = 0; i < approvers.length; i++) { // Đảm bảo người đề xuất không tự duyệt
            require(approvers[i] != msg.sender, "RM: Nguoi de xuat cap vai tro khong duoc tu phe duyet");
        }
        uint256 approvalSharesPercent = _sumSharesPercentage(approvers);
        require(approvalSharesPercent > 5000, "RM: Khong du co phan phe duyet");
        _grantRole(role, account);
    }

    function revokeRoleByBoard(bytes32 role, address account, address[] memory approvers) external onlyActiveBoardMember {
         require(
            role == WAREHOUSE_DIRECTOR_ROLE ||
            role == STORE_DIRECTOR_ROLE ||
            role == FINANCE_DIRECTOR_ROLE ||
            role == SUPPLIER_ROLE, "RM: Vai tro khong hop le de BDH cap/thu hoi"
        );
        require(account != address(0), "RM: Tai khoan khong hop le");
        require(approvers.length > 0, "RM: Can nguoi phe duyet");
        for(uint i = 0; i < approvers.length; i++) { // Đảm bảo người đề xuất không tự duyệt
            require(approvers[i] != msg.sender, "RM: Nguoi de xuat thu hoi vai tro khong duoc tu phe duyet");
        }
        uint256 approvalSharesPercent = _sumSharesPercentage(approvers);
        require(approvalSharesPercent > 5000, "RM: Khong du co phan phe duyet");
        _revokeRole(role, account);
    }

    // Các hàm cấp/thu hồi vai trò Manager bởi Director tương ứng
    function grantWarehouseManager(address account) external {
        require(hasRole(WAREHOUSE_DIRECTOR_ROLE, msg.sender), "RM: Chi GD Kho duoc phep");
        _grantRole(WAREHOUSE_MANAGER_ROLE, account);
    }
    function revokeWarehouseManager(address account) external {
         require(hasRole(WAREHOUSE_DIRECTOR_ROLE, msg.sender), "RM: Chi GD Kho duoc phep");
        _revokeRole(WAREHOUSE_MANAGER_ROLE, account);
    }

    function grantStoreManager(address account) external {
        require(hasRole(STORE_DIRECTOR_ROLE, msg.sender), "RM: Chi GD Cua hang duoc phep");
        _grantRole(STORE_MANAGER_ROLE, account);
    }
    function revokeStoreManager(address account) external {
        require(hasRole(STORE_DIRECTOR_ROLE, msg.sender), "RM: Chi GD Cua hang duoc phep");
        _revokeRole(STORE_MANAGER_ROLE, account);
    }

    // --- View Functions ---
    function getBoardMembers() external view returns (address[] memory) { return boardAddresses; }
    function getBoardMemberInfo(address member) external view returns (BoardMember memory) { return boardMembers[member]; }

    // --- Role ID Getters ---
    function BOARD_ROLE_ID() external pure returns (bytes32) { return BOARD_ROLE; }
    function WAREHOUSE_DIRECTOR_ROLE_ID() external pure returns (bytes32) { return WAREHOUSE_DIRECTOR_ROLE; }
    function STORE_DIRECTOR_ROLE_ID() external pure returns (bytes32) { return STORE_DIRECTOR_ROLE; }
    function FINANCE_DIRECTOR_ROLE_ID() external pure returns (bytes32) { return FINANCE_DIRECTOR_ROLE; }
    function WAREHOUSE_MANAGER_ROLE_ID() external pure returns (bytes32) { return WAREHOUSE_MANAGER_ROLE; }
    function STORE_MANAGER_ROLE_ID() external pure returns (bytes32) { return STORE_MANAGER_ROLE; }
    function SUPPLIER_ROLE_ID() external pure returns (bytes32) { return SUPPLIER_ROLE; }
    function DEFAULT_ADMIN_ROLE_ID() external pure returns (bytes32) { return DEFAULT_ADMIN_ROLE; }
}