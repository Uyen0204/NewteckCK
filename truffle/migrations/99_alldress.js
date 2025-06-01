const RoleManagement = artifacts.require("RoleManagement");
const ItemsManagement = artifacts.require("ItemsManagement");
const CompanyTreasuryManager = artifacts.require("CompanyTreasuryManager");
const WarehouseInventoryManagement = artifacts.require("WarehouseInventoryManagement");
const StoreInventoryManagement = artifacts.require("StoreInventoryManagement");
const WarehouseSupplierOrderManagement = artifacts.require("WarehouseSupplierOrderManagement");
const CustomerOrderManagement = artifacts.require("CustomerOrderManagement");

module.exports = async function (deployer, network, accounts) {
  const deployerAccount = accounts[0]; // Người thực hiện các lệnh set, thường là owner của các contract

  // Lấy tất cả các instance đã deploy
  // Sử dụng try-catch để xử lý trường hợp một contract nào đó chưa được deploy (mặc dù không nên xảy ra nếu thứ tự đúng)
  let rmInstance, imInstance, ctmInstance, wimInstance, simInstance, wsomInstance, comInstance;

  try {
    rmInstance = await RoleManagement.deployed();
    imInstance = await ItemsManagement.deployed();
    ctmInstance = await CompanyTreasuryManager.deployed();
    wimInstance = await WarehouseInventoryManagement.deployed();
    simInstance = await StoreInventoryManagement.deployed();
    wsomInstance = await WarehouseSupplierOrderManagement.deployed();
    comInstance = await CustomerOrderManagement.deployed();
  } catch (e) {
    console.error("Lỗi khi lấy instance của một hoặc nhiều contract đã deploy. Đảm bảo tất cả đã được deploy trước khi chạy script này.", e);
    return;
  }

  console.log("=== Bắt đầu thiết lập liên kết địa chỉ giữa các contract ===");

  // 1. RoleManagement cần biết địa chỉ CTM (cho onlyCTM modifier trong activateBoardMemberByTreasury)
  if (rmInstance && ctmInstance) {
    console.log(`Thiết lập CTM address (${ctmInstance.address}) cho RoleManagement...`);
    await rmInstance.setCompanyTreasuryManagerAddress(ctmInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập CTM cho RM.");
  } else {
    console.warn("Không thể thiết lập CTM cho RM: Một hoặc cả hai contract chưa sẵn sàng.");
  }

  // 2. CompanyTreasuryManager (CTM) cần biết địa chỉ WSOM và COM
  if (ctmInstance && wsomInstance) {
    console.log(`Thiết lập WSOM address (${wsomInstance.address}) cho CTM...`);
    await ctmInstance.setWarehouseSupplierOrderManagementAddress(wsomInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập WSOM cho CTM.");
  } else {
    console.warn("Không thể thiết lập WSOM cho CTM: Một hoặc cả hai contract chưa sẵn sàng.");
  }
  if (ctmInstance && comInstance) {
    console.log(`Thiết lập COM address (${comInstance.address}) cho CTM...`);
    await ctmInstance.setCustomerOrderManagementAddress(comInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập COM cho CTM.");
  } else {
    console.warn("Không thể thiết lập COM cho CTM: Một hoặc cả hai contract chưa sẵn sàng.");
  }
  // CTM cũng có setRoleManagementFullAddress, nhưng nó đã được truyền qua constructor và có thể được cập nhật riêng nếu cần nâng cấp RM.

  // 3. WarehouseSupplierOrderManagement (WSOM) cần biết địa chỉ WIM
  if (wsomInstance && wimInstance) {
    console.log(`Thiết lập WIM address (${wimInstance.address}) cho WSOM...`);
    await wsomInstance.setWarehouseInventoryManagementAddress(wimInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập WIM cho WSOM.");
  } else {
    console.warn("Không thể thiết lập WIM cho WSOM: Một hoặc cả hai contract chưa sẵn sàng.");
  }
  
  // 4. WarehouseInventoryManagement (WIM) cần biết địa chỉ SIM và WSOM
  if (wimInstance && simInstance) {
    console.log(`Thiết lập SIM address (${simInstance.address}) cho WIM...`);
    await wimInstance.setStoreInventoryManagementAddress(simInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập SIM cho WIM.");
  } else {
    console.warn("Không thể thiết lập SIM cho WIM: Một hoặc cả hai contract chưa sẵn sàng.");
  }
  if (wimInstance && wsomInstance) { // WSOM để WIM biết ai gọi recordStockInFromSupplier
    console.log(`Thiết lập WSOM address (${wsomInstance.address}) cho WIM...`);
    await wimInstance.setWarehouseSupplierOrderManagementAddress(wsomInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập WSOM cho WIM.");
  } else {
    console.warn("Không thể thiết lập WSOM cho WIM: Một hoặc cả hai contract chưa sẵn sàng.");
  }

  // 5. StoreInventoryManagement (SIM) cần biết địa chỉ WIM
  if (simInstance && wimInstance) {
    console.log(`Thiết lập WIM address (${wimInstance.address}) cho SIM...`);
    await simInstance.setWarehouseInventoryManagementAddress(wimInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập WIM cho SIM.");
  } else {
    console.warn("Không thể thiết lập WIM cho SIM: Một hoặc cả hai contract chưa sẵn sàng.");
  }

  // 6. CustomerOrderManagement (COM) cần biết địa chỉ SIM và WIM (cho returns)
  if (comInstance && simInstance) {
    console.log(`Thiết lập SIM address (${simInstance.address}) cho COM...`);
    await comInstance.setStoreInventoryManagementAddress(simInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập SIM cho COM.");
  } else {
    console.warn("Không thể thiết lập SIM cho COM: Một hoặc cả hai contract chưa sẵn sàng.");
  }
  if (comInstance && wimInstance) {
    console.log(`Thiết lập WIM address (${wimInstance.address}) cho COM (cho returns)...`);
    await comInstance.setWarehouseInventoryManagementAddress(wimInstance.address, { from: deployerAccount });
    console.log("  -> Đã thiết lập WIM cho COM (returns).");
  } else {
    console.warn("Không thể thiết lập WIM cho COM (returns): Một hoặc cả hai contract chưa sẵn sàng.");
  }
  
  // Thiết lập các vai trò ban đầu quan trọng khác nếu cần
  // Ví dụ: Thiết lập Giám đốc Tài chính ban đầu cho CTM
  if (ctmInstance && rmInstance) {
    // Chọn một tài khoản để làm Giám đốc Tài chính ban đầu
    // Đảm bảo tài khoản này đã được cấp FINANCE_DIRECTOR_ROLE trong RoleManagement
    // Việc cấp vai trò này có thể thực hiện thủ công sau khi RM deploy, hoặc trong một script setup vai trò riêng.
    const initialFinanceDirector = accounts[1]; // Ví dụ: tài khoản thứ hai từ Ganache
    // Kiểm tra xem người này đã có vai trò chưa, nếu chưa thì không set được
    const financeDirectorRoleId = await rmInstance.FINANCE_DIRECTOR_ROLE_ID();
    const hasFinRole = await rmInstance.hasRole(financeDirectorRoleId, initialFinanceDirector);

    if (hasFinRole) {
        console.log(`Thiết lập Giám đốc Tài chính ban đầu (${initialFinanceDirector}) cho CTM...`);
        await ctmInstance.setInitialFinanceDirector(initialFinanceDirector, { from: deployerAccount });
        console.log("  -> Đã thiết lập Giám đốc Tài chính.");
    } else {
        console.warn(`CẢNH BÁO: Tài khoản ${initialFinanceDirector} chưa có vai trò FINANCE_DIRECTOR_ROLE. Không thể thiết lập làm GĐTC ban đầu cho CTM.`);
        console.warn(`  -> Vui lòng cấp vai trò FINANCE_DIRECTOR_ROLE cho ${initialFinanceDirector} trong RoleManagement trước.`);
    }
  }

  console.log("=== Hoàn tất thiết lập liên kết địa chỉ và các thiết lập cơ bản ===");
};