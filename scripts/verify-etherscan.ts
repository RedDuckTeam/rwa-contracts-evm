/**
 * Publishes sources for every contract in a deployment.
 *
 *   pnpm verify:etherscan --network sepolia
 *
 * MUST run on the same build profile the deployment used, because verification matches the
 * deployed bytecode against locally compiled artifacts and an optimizer setting is part of
 * that bytecode. The `verify:etherscan` package script pins `--build-profile production`.
 *
 * The seven UUPS proxies go through the plain `verify` task, which @openzeppelin/hardhat-upgrades
 * overrides: it verifies the implementation, verifies the ERC-1967 proxy from its own bundled
 * artifact, and registers the proxy -> implementation link so the explorer offers "Read as
 * Proxy". Passing the implementation address directly would verify the code and leave the
 * proxy an unreadable blob.
 *
 * The two plain contracts need constructor arguments, which the task only accepts as a module
 * path — its inline form is typed `string[]`, and the timelock takes `address[]`. The module is
 * generated here from `deployment.json` rather than written at deploy time, so there is one
 * source for the values and no artefact that can drift from the deployment it describes.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import hre from "hardhat";
import type { Address } from "viem";

import { readDeploymentRecordForChain } from "./lib/deployment.js";

const log = (message: string) => console.log(message);

const connection = await hre.network.getOrCreate();

const EPHEMERAL = /^(default|hardhat.*)$/;
if (EPHEMERAL.test(connection.networkName)) {
  log(`Network "${connection.networkName}" is an in-memory development chain.`);
  log("There is no block explorer to publish to. Pass --network <a real network>.");
  process.exit(1);
}

const publicClient = await connection.viem.getPublicClient();
const { addresses, config } = readDeploymentRecordForChain(
  connection.networkName,
  await publicClient.getChainId(),
);

const ZERO = "0x0000000000000000000000000000000000000000";

interface Target {
  label: string;
  address: Address;
  /** Absent for the proxies: they take no constructor arguments the task must be told about. */
  constructorArgs?: unknown[];
}

const targets: Target[] = [
  {
    label: "RwaTimelockController",
    address: addresses.timelock,
    // Exactly the arguments `deployPlatform` passes: proposer is the admin, the executor is
    // open, and there is no admin so the role set is final.
    constructorArgs: [config.timelockDelaySeconds, [addresses.admin], [ZERO], ZERO],
  },
  { label: "AccessRegistry", address: addresses.accessRegistry },
  { label: "ComplianceRegistry", address: addresses.complianceRegistry },
  { label: "AdminNavAggregator", address: addresses.aggregator },
  { label: "DataFeed", address: addresses.dataFeed },
  { label: "WbondToken", address: addresses.token },
  { label: "DepositVault", address: addresses.depositVault },
  { label: "RedemptionVault", address: addresses.redemptionVault },
];

// Non-zero only when `deploy.ts` deployed the stand-in. A real stablecoin is somebody else's
// contract and is already verified.
if (addresses.paymentToken !== ZERO) {
  targets.push({
    label: "MockERC20 (payment token)",
    address: addresses.paymentToken,
    constructorArgs: ["USD Coin", "USDC", 6],
  });
}

const argsDir = join(process.cwd(), "deployments", connection.networkName, "constructor-args");

function writeConstructorArgsModule(label: string, args: unknown[]): string {
  mkdirSync(argsDir, { recursive: true });
  const path = join(argsDir, `${label.replace(/[^A-Za-z0-9]/g, "-")}.js`);
  // JSON cannot carry a bigint, and the module is imported as JS rather than parsed, so the
  // values are emitted as source with the `n` suffix intact.
  const literal = (value: unknown): string =>
    typeof value === "bigint"
      ? `${value.toString()}n`
      : Array.isArray(value)
        ? `[${value.map(literal).join(", ")}]`
        : JSON.stringify(value);

  writeFileSync(path, `export default [${args.map(literal).join(", ")}];\n`);
  return path;
}

const verifyTask = hre.tasks.getTask("verify");

const failed: string[] = [];
for (const target of targets) {
  log("");
  log(`=== ${target.label} — ${target.address} ===`);

  // The task reports failure by SETTING process.exitCode rather than throwing, so it has to be
  // cleared before each run: left over from an earlier target it would attribute one
  // contract's failure to every contract after it.
  process.exitCode = 0;
  try {
    await verifyTask.run({
      address: target.address,
      ...(target.constructorArgs === undefined
        ? {}
        : {
            constructorArgsPath: writeConstructorArgsModule(target.label, target.constructorArgs),
          }),
    });
    if (process.exitCode !== 0) failed.push(target.label);
  } catch (error) {
    log(error instanceof Error ? error.message : String(error));
    failed.push(target.label);
  }
}

process.exitCode = 0;
log("");
if (failed.length > 0) {
  log(`Verification failed for: ${failed.join(", ")}`);
  log("");
  log("Two causes account for nearly all of these:");
  log("  - a build profile mismatch. Verification compares the DEPLOYED bytecode against a");
  log("    local compile, and the optimizer setting is part of that bytecode. Deploy and");
  log("    verify must both use --build-profile production.");
  log("  - the explorer has not indexed the deployment yet. Wait a few blocks and re-run;");
  log("    contracts already verified are reported as such and cost nothing to retry.");
  process.exitCode = 1;
} else {
  log(`All ${targets.length} contracts verified on ${connection.networkName}.`);
}
