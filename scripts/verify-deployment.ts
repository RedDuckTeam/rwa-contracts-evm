/**
 * Audits a deployment's role wiring and configuration.
 *
 *   pnpm verify-deployment
 *   EXPECT_LIVE=1 pnpm hardhat run scripts/verify-deployment.ts --network sepolia
 *
 * Run after the multisig has executed `grants.json` AND the scheduled critical grant has
 * matured, but BEFORE anything is unpaused; it exits non-zero on failure, so it can gate
 * the unpause step. It expects everything still paused, which is the state a correct
 * handover is in at that point — `EXPECT_LIVE=1` re-audits a running deployment instead.
 */
import hre from "hardhat";

import { readDeploymentRecordForChain } from "./lib/deployment.js";
import { printReport, verifyDeployment } from "./lib/verify.js";

const log = (message: string) => console.log(message);

const connection = await hre.network.getOrCreate();
const expectPaused = process.env.EXPECT_LIVE === undefined;

// Refuse an ephemeral network BEFORE reading from disk. `hardhat run` starts a fresh
// in-memory chain each invocation, so an address book from a previous run points at nothing.
// Checked first so the explanation is reachable: reading the record would otherwise throw on
// a missing file and this guard would be dead code.
const EPHEMERAL = /^(default|hardhat.*)$/;
if (EPHEMERAL.test(connection.networkName)) {
  log(`Network "${connection.networkName}" is an in-memory development chain.`);
  log("");
  log("Each `hardhat run` starts a fresh chain, so nothing survives between invocations and");
  log("there is no deployment here to audit. `pnpm deploy:local` runs this same audit inline —");
  log("before and after unpausing — which is where the local check lives.");
  log("");
  log("For a real deployment, pass --network <name> pointing at a persistent chain.");
  process.exit(1);
}

const publicClient = await connection.viem.getPublicClient();
const { addresses, holders, config } = readDeploymentRecordForChain(
  connection.networkName,
  await publicClient.getChainId(),
);

log(`network:  ${addresses.network}`);
log(`registry: ${addresses.accessRegistry}`);
log(`expecting operations to be ${expectPaused ? "PAUSED (pre-unpause audit)" : "LIVE"}`);
log("");

const code = await publicClient.getCode({ address: addresses.accessRegistry });
if (code === undefined || code === "0x") {
  log(`No contract at ${addresses.accessRegistry} on ${connection.networkName}.`);
  log("The recorded deployment does not exist on this chain — check --network.");
  process.exit(1);
}

// Holders and config come from the persisted record — what the deployment ACTUALLY used — so
// a non-default role assignment is audited against its own wiring, not the template's.
const report = await verifyDeployment(connection, addresses, { expectPaused, holders, config });
printReport(report, log);

if (!report.passed) {
  log("");
  log("Do NOT unpause. Fix the wiring above and re-run.");
  process.exit(1);
}

if (expectPaused) {
  log("");
  log("Wiring is correct. Post NAV, then unpause — in that order.");
}
