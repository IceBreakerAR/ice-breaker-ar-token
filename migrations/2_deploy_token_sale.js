const IceBreakerARTokenSale = artifacts.require("./IceBreakerARTokenSale.sol");


module.exports = function (deployer, network) {
  if (network === "development") {
    // don't deploy if running tests
    return true;
  }

  let vaultAddress = process.env.VAULT_ADDRESS;
  if (!vaultAddress) {
    throw new Error("Vault Address not set");
  }
  console.log("Using Vault Address:", vaultAddress);

  let kycAddress = process.env.KYC_ADDRESS;
  if (!kycAddress) {
    throw new Error("KYC Address not set");
  }
  console.log("Using KYC Address:", kycAddress);

  let tokenBaseRate = parseInt(process.env.TOKEN_BASE_RATE, 10);
  if (!tokenBaseRate) {
    throw new Error("Token Base Rate not set");
  }
  console.log("Using Token Base Rate:", tokenBaseRate);

  let referrerBonusRate = parseInt(process.env.REFERRER_BONUS_RATE, 10);
  if (!referrerBonusRate) {
    throw new Error("Referrer Bonus Rate not set");
  }
  console.log("Using Referrer Bonus Rate:", referrerBonusRate);


  let maxTxGasPrice = 50 * 10 ** 9; // 50 GWei

  return deployer.deploy(IceBreakerARTokenSale, vaultAddress, kycAddress, tokenBaseRate, referrerBonusRate, maxTxGasPrice);
};
