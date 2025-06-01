const RoleManagement = artifacts.require("RoleManagement");
const ItemsManagement = artifacts.require("ItemsManagement");
const CompanyTreasuryManager = artifacts.require("CompanyTreasuryManager");
const CustomerOrderManagement = artifacts.require("CustomerOrderManagement"); // Đảm bảo tên này khớp

module.exports = async function (deployer, network, accounts) {
  const deployerAccount = accounts[0];

  // Lấy instance của các contract đã deploy trước đó
  const roleManagementInstance = await RoleManagement.deployed();
  const itemsManagementInstance = await ItemsManagement.deployed();
  const companyTreasuryManagerInstance = await CompanyTreasuryManager.deployed();

  if (!roleManagementInstance || !itemsManagementInstance || !companyTreasuryManagerInstance) {
    console.error("LỖI: Một hoặc nhiều contract phụ thuộc (RM, IM, CTM) chưa được deploy! Không thể deploy CustomerOrderManagement.");
    return; 
  }

  console.log(`Deploying CustomerOrderManagement với:`);
  console.log(`  - RoleManagement tại: ${roleManagementInstance.address}`);
  console.log(`  - ItemsManagement tại: ${itemsManagementInstance.address}`);
  console.log(`  - CompanyTreasuryManager tại: ${companyTreasuryManagerInstance.address}`);
  
  await deployer.deploy(
    CustomerOrderManagement,
    roleManagementInstance.address,
    itemsManagementInstance.address,
    companyTreasuryManagerInstance.address, // Địa chỉ của CTM để COM có thể chuyển tiền vào
    { from: deployerAccount }
  );

  const comInstance = await CustomerOrderManagement.deployed();
  console.log("CustomerOrderManagement đã được deploy tại:", comInstance.address);

  // LƯU Ý QUAN TRỌNG:
  // Các hàm setStoreInventoryManagementAddress và setWarehouseInventoryManagementAddress trên comInstance
  // sẽ cần được gọi trong script migration setup chung (ví dụ: 99_setup_all_addresses.js)
  // sau khi StoreInventoryManagement (SIM) và WarehouseInventoryManagement (WIM) đã được deploy.
};