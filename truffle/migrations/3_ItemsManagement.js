// migrations/3_deploy_items_management.js
const RoleManagement = artifacts.require("RoleManagement");
const ItemsManagement = artifacts.require("ItemsManagement");

module.exports = async function (deployer, network, accounts) {
  // Đảm bảo RoleManagement đã được deploy
  const roleManagementInstance = await RoleManagement.deployed();
  if (!roleManagementInstance) {
    console.error("LỖI: RoleManagement contract chưa được deploy hoặc deploy thất bại!");
    return; // Dừng nếu không tìm thấy RoleManagement
  }

  console.log("Deploying ItemsManagement với RoleManagement tại:", roleManagementInstance.address);
  await deployer.deploy(ItemsManagement, roleManagementInstance.address);

  const itemsManagementInstance = await ItemsManagement.deployed();
  console.log("ItemsManagement đã được deploy tại:", itemsManagementInstance.address);
};