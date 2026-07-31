/**
 * Prepares a UUPS upgrade and validates it against the deployed storage layout.
 *
 *   UPGRADE_TARGET=depositVault UPGRADE_CONTRACT=DepositVaultV2 \
 *     pnpm hardhat run scripts/upgrade.ts --network sepolia --build-profile production
 *
 * It never executes the upgrade: `_authorizeUpgrade` requires `UPGRADER_ROLE`, held only by
 * the TimelockController, so an upgrade is necessarily a scheduled proposal. It:
 *
 *   1. runs the OpenZeppelin storage-layout validation against the CURRENTLY DEPLOYED
 *      implementation, so an incompatible change is caught before a proposal exists;
 *   2. deploys the new implementation;
 *   3. prints the exact `schedule` / `execute` calldata for the multisig.
 *
 * The `.openzeppelin/` manifest is what makes step 1 possible — it records the layout of
 * every deployed implementation. COMMIT IT.
 */
import hre from "hardhat";
import { encodeFunctionData } from "viem";

import { REFERENCE_CONFIG } from "./config.js";
import { readAddressBook, type AddressBook } from "./lib/deployment.js";

const log = (message: string) => console.log(message);

const target = process.env.UPGRADE_TARGET;
const contractName = process.env.UPGRADE_CONTRACT;

if (target === undefined || contractName === undefined) {
  log("usage: UPGRADE_TARGET=<key> UPGRADE_CONTRACT=<ContractName> hardhat run scripts/upgrade.ts");
  log("  <key> is a proxy key from deployments/<network>/addresses.json, e.g. depositVault");
  process.exit(1);
}

const connection = await hre.network.getOrCreate();
const addresses = readAddressBook(connection.networkName);

const proxy = (addresses as unknown as Record<string, string>)[target];
if (proxy === undefined || !proxy.startsWith("0x")) {
  log(`unknown target "${target}". Known keys: ${Object.keys(addresses).join(", ")}`);
  process.exit(1);
}

const { upgrades } = await import("@openzeppelin/hardhat-upgrades/viem");
const api = await upgrades(hre, connection);

log(`proxy:       ${proxy}`);
log(`new impl:    ${contractName}`);
log("");

// Reverts on any incompatibility: an inserted variable, a changed type, a deleted namespace.
log("validating storage layout against the deployed implementation...");
await api.validateUpgrade(proxy as `0x${string}`, contractName, { kind: "uups" });
log("  layout is compatible");

log("");
log("deploying the new implementation...");
const implementation = await api.deployImplementation(contractName, { kind: "uups" });
log(`  implementation: ${String(implementation)}`);

const upgradeCalldata = encodeFunctionData({
  abi: [
    {
      type: "function",
      name: "upgradeToAndCall",
      inputs: [
        { name: "newImplementation", type: "address" },
        { name: "data", type: "bytes" },
      ],
      outputs: [],
      stateMutability: "payable",
    },
  ],
  functionName: "upgradeToAndCall",
  // Empty init data. A version that adds state uses `reinitializer(n)` and puts the encoded
  // call here instead, so the upgrade and the migration are one atomic step.
  args: [String(implementation) as `0x${string}`, "0x"],
});

printProposal(addresses, proxy as `0x${string}`, upgradeCalldata);

function printProposal(book: AddressBook, proxyAddress: `0x${string}`, data: `0x${string}`): void {
  log("");
  log("Schedule this on the timelock, from the multisig:");
  log(`  timelock:    ${book.timelock}`);
  log(`  target:      ${proxyAddress}`);
  log("  value:       0");
  log(`  data:        ${data}`);
  log("  predecessor: 0x" + "0".repeat(64));
  log("  salt:        0x" + "0".repeat(64));
  log(`  delay:       ${REFERENCE_CONFIG.timelockDelaySeconds} seconds`);
  log("");
  log("After the delay, anyone may execute it — the timelock has an open executor.");
  log("Re-run verify-deployment afterwards: an upgrade can change role wiring.");
}
