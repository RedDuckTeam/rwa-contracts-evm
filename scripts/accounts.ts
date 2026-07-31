/**
 * Prints the accounts a network is configured with, their balances, and which of them the
 * deploy expects in which role.
 *
 *   pnpm accounts --network sepolia
 *
 * Run it before editing `scripts/config.ts`: the addresses that go into `operationalHolders`
 * are derived from the private keys, and there is otherwise no way to know them without
 * deploying something first.
 */
import hre from "hardhat";
import { formatEther, getAddress } from "viem";

import { configForNetwork } from "./config.js";

const log = (message: string) => console.log(message);

const connection = await hre.network.getOrCreate();
const publicClient = await connection.viem.getPublicClient();
const wallets = await connection.viem.getWalletClients();

log(`network: ${connection.networkName} (chain ${await publicClient.getChainId()})`);
log("");

const [deployerWallet, adminWallet] = wallets;
if (deployerWallet === undefined) {
  log("No accounts configured for this network. Check `accounts` in hardhat.config.ts.");
  process.exit(1);
}

for (const [index, wallet] of wallets.entries()) {
  const address = getAddress(wallet.account.address);
  const balance = await publicClient.getBalance({ address });
  const role = index === 0 ? "deployer" : index === 1 ? "admin (DEPLOY_ADMIN)" : "";
  log(`  [${index}] ${address}  ${formatEther(balance).padStart(12)} ETH  ${role}`);
}

const config = configForNetwork(connection.networkName);
const deployer = getAddress(deployerWallet.account.address);

log("");
log("Fill scripts/config.ts with:");
log(`  operationalHolders.pauser:          ${deployer}`);
log(`  operationalHolders.requestOperator: ${deployer}`);
log("");
log("and export the admin address, which must NOT be the deployer:");
log(
  adminWallet === undefined
    ? "  DEPLOY_ADMIN=0x<a second account>   (only one key is configured — `pnpm handover` " +
        "needs the admin's key too)"
    : `  DEPLOY_ADMIN=${getAddress(adminWallet.account.address)}`,
);

if (config.acceptShortTimelockDelay === true) {
  log("");
  log(
    `NOTE: this network's config runs a ${config.timelockDelaySeconds}s timelock, below the ` +
      "48h production floor. Testnet only.",
  );
}
