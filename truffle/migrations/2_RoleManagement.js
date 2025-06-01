const RoleManagement = artifacts.require("RoleManagement");

module.exports = function (deployer) {
  deployer.deploy(RoleManagement);
};