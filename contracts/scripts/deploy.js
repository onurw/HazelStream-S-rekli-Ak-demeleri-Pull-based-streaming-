const hre = require("hardhat");
async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  // Demo için ERC20 adresi gerekecek; gerçek kullanımda sabit bir stablecoin adresi verirsin.
  // Yerelde test etmek için 01-erc20-token projesindeki tokenı deploy edip adresini buraya koyabilirsin.
  const tokenAddress = process.env.ERC20 || "0x0000000000000000000000000000000000000000";
  const C = await hre.ethers.getContractFactory("HazelStream");
  const c = await C.deploy(tokenAddress);
  await c.waitForDeployment();
  console.log("HazelStream:", await c.getAddress());
}
main().catch((e)=>{console.error(e);process.exitCode=1;});
