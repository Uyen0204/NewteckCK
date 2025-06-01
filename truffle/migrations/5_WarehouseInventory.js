// migrations/6_deploy_wim.js

const RoleManagement = artifacts.require("RoleManagement");
const ItemsManagement = artifacts.require("ItemsManagement"); // Nếu constructor của WIM cần ItemsManagement
const WarehouseInventoryManagement = artifacts.require("WarehouseInventoryManagement");

module.exports = async function (deployer, network, accounts) {
  const deployerAccount = accounts[0];

  // Lấy instance của các contract đã deploy trước đó
  const roleManagementInstance = await RoleManagement.deployed();
  // const itemsManagementInstance = await ItemsManagement.deployed(); // Bỏ comment nếu constructor của WIM cần

  if (!roleManagementInstance) {
    console.error("LỖI: RoleManagement contract chưa được deploy! Không thể deploy WIM.");
    return;
  }
  // if (!itemsManagementInstance) { // Bỏ comment nếu constructor của WIM cần
  //   console.error("LỖI: ItemsManagement contract chưa được deploy! Không thể deploy WIM.");
  //   return;
  // }

  console.log(`Deploying WarehouseInventoryManagement với:`);
  console.log(`  - RoleManagement tại: ${roleManagementInstance.address}`);
  // console.log(`  - ItemsManagement tại: ${itemsManagementInstance.address}`); // Bỏ comment nếu constructor của WIM cần
  
  await deployer.deploy(
    WarehouseInventoryManagement,
    roleManagementInstance.address,
    // itemsManagementInstance.address, // Bỏ comment nếu constructor của WIM cần địa chỉ ItemsM
    { from: deployerAccount }
  );

  const wimInstance = await WarehouseInventoryManagement.deployed();
  console.log("WarehouseInventoryManagement đã được deploy tại:", wimInstance.address);
};