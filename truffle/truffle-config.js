module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",     // Localhost (default: none)
      port: 7545,            // Port của Ganache
      network_id: "5777",       // Match any network id
    },
  },
  compilers: {
    solc: {
      version: "0.8.0"   // Match với version trong smart contract
    }
  }
};