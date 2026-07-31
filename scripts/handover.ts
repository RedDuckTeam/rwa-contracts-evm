/**
 * Stage 2 of the deployment: everything between `deploy.ts` stopping and a live product.
 *
 *   pnpm handover --network sepolia
 *
 * This is docs/FORKING.md §3 stage 2, run end to end instead of by hand. It requires the
 * ADMIN's key to be configured for the network — with a Safe multisig admin, execute
 * `grants.json` through the Safe UI first and then run this: every step is resumable, so it
 * picks up from whatever has already landed.
 *
 * The order is not cosmetic. Verification gates the unpause, and a price is posted before any
 * user-facing operation opens — the reverse would open a product whose every priced path
 * reverts. Nothing here can be skipped by re-running.
 *
 * Environment:
 *   SKIP_SMOKE_TEST=1     do not run the closing mint -> redeem check
 *   HANDOVER_FLOAT        treasury float to mint, in whole units (default 10000000). Only
 *                         applies when the payment token is the deploy script's MockERC20.
 */
import hre from "hardhat";
import { formatUnits, getAddress, parseUnits, type Address } from "viem";

import {
  OP_IDS,
  grantBatchExists,
  readDeploymentRecordForChain,
  readGrantBatch,
} from "./lib/deployment.js";
import {
  executeScheduledRefundGrant,
  readPausePosture,
  refundGrantStatus,
  replayGrantsResumable,
  unpauseAll,
} from "./lib/handover.js";
import { printReport, verifyDeployment } from "./lib/verify.js";

const log = (message: string) => console.log(message);
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const connection = await hre.network.getOrCreate();

// `hardhat run` starts a fresh in-memory chain each invocation, so a deployment record from a
// previous run points at nothing. Checked before reading from disk so the explanation is
// reachable rather than buried under a missing-file error.
const EPHEMERAL = /^(default|hardhat.*)$/;
if (EPHEMERAL.test(connection.networkName)) {
  log(`Network "${connection.networkName}" is an in-memory development chain.`);
  log("Nothing survives between invocations, so there is no deployment here to hand over.");
  log("`pnpm deploy:local` performs the deploy and this handover in one process.");
  process.exit(1);
}

if (!grantBatchExists(connection.networkName)) {
  log(`No deployments/${connection.networkName}/grants.json.`);
  log("Run the deploy first:");
  log(`  DEPLOY_ADMIN=0x<admin> pnpm deploy:${connection.networkName}`);
  process.exit(1);
}

const publicClient = await connection.viem.getPublicClient();
const { addresses, holders, config } = readDeploymentRecordForChain(
  connection.networkName,
  await publicClient.getChainId(),
);

const code = await publicClient.getCode({ address: addresses.accessRegistry });
if (code === undefined || code === "0x") {
  log(`No contract at ${addresses.accessRegistry} on ${connection.networkName}.`);
  log("The recorded deployment does not exist on this chain — check --network.");
  process.exit(1);
}

/* ------------------------------------------------------------------------ */
/*                    Signers: fail before the first send                   */
/* ------------------------------------------------------------------------ */

const available = new Set(
  (await connection.viem.getWalletClients()).map((wallet) => getAddress(wallet.account.address)),
);

/**
 * Checked up front for every role this run will need. Discovering a missing key three
 * transactions in leaves the deployment half-handed-over, which is the state the whole
 * resumable design exists to make survivable — but not needing to reach it is better.
 */
function requireKey(label: string, account: Address): Address {
  const address = getAddress(account);
  if (!available.has(address)) {
    throw new Error(
      `no configured key for the ${label} account (${address}) on ${connection.networkName}. ` +
        "Add its private key to the network's `accounts` in hardhat.config.ts — see " +
        "docs/SEPOLIA.md §1. If the admin is a multisig, execute grants.json through its UI " +
        "and re-run: this script resumes from whatever has already landed.",
    );
  }
  return address;
}

const runSmokeTest = process.env.SKIP_SMOKE_TEST !== "1";

const admin = requireKey("admin", addresses.admin);
const hasTreasuryActions = grantBatchExists(connection.networkName, "treasury-actions.json");
const treasury = hasTreasuryActions ? requireKey("treasury", addresses.treasury) : addresses.treasury;
const unpauser = requireKey("UNPAUSER", holders.unpauser);
const feedOperator = requireKey("FEED_OPERATOR", holders.feedOperator);
// Needed only to admit the smoke-test account, and only while the greenlist is the gate. A
// fork that keeps this role on a compliance bot should not be blocked from handing over just
// because that key is elsewhere.
const needsGreenlistKey = runSmokeTest && config.compliance.greenlistEnabled;
const greenlistOperator = needsGreenlistKey
  ? requireKey("GREENLIST_OPERATOR", holders.greenlistOperator)
  : holders.greenlistOperator;

log(`network:  ${connection.networkName}`);
log(`registry: ${addresses.accessRegistry}`);
log(`admin:    ${admin}`);
log(`treasury: ${treasury}`);
log("");

/* ------------------------------------------------------------------------ */
/*                       1 — the role and market batch                      */
/* ------------------------------------------------------------------------ */

log("replaying grants.json...");
const multisigBatch = await replayGrantsResumable(
  connection,
  admin,
  readGrantBatch(connection.networkName),
  log,
);
log(`  ${multisigBatch.sent} sent, ${multisigBatch.skipped} skipped`);

if (hasTreasuryActions) {
  log("");
  log("replaying treasury-actions.json AS THE TREASURY...");
  const treasuryBatch = await replayGrantsResumable(
    connection,
    treasury,
    readGrantBatch(connection.networkName, "treasury-actions.json"),
    log,
  );
  log(`  ${treasuryBatch.sent} sent, ${treasuryBatch.skipped} skipped`);
}

/* ------------------------------------------------------------------------ */
/*                     2 — the one grant only time can give                 */
/* ------------------------------------------------------------------------ */

log("");
const status = await refundGrantStatus(connection, addresses);

if (status.state === "unscheduled") {
  throw new Error(
    "the REFUND_VAULT grant is not scheduled on the timelock. The last entry of grants.json " +
      "schedules it; it was skipped above, or the batch was never executed by the admin. " +
      "Without it, every redemption refund fails once the system is live.",
  );
}

if (status.state === "done") {
  log("REFUND_VAULT grant: already executed");
} else {
  if (status.state === "pending") {
    const { timestamp: now } = await publicClient.getBlock();
    log(
      `REFUND_VAULT grant matures in ${status.readyAt - now}s ` +
        `(timelock delay ${config.timelockDelaySeconds}s). Waiting...`,
    );
    // Polls the CHAIN's clock rather than the local one: a testnet's block timestamps drift
    // from wall time, and a delay counted locally would either execute early and revert or
    // sit past maturity waiting for a clock nobody is watching.
    for (;;) {
      const block = await publicClient.getBlock();
      if (block.timestamp >= status.readyAt) break;
      const remaining = Number(status.readyAt - block.timestamp);
      log(`  ${remaining}s remaining`);
      await sleep(Math.min(remaining + 1, 30) * 1000);
    }
  }

  await executeScheduledRefundGrant(connection, addresses);
  log("REFUND_VAULT grant: executed -> RedemptionVault");
}

/* ------------------------------------------------------------------------ */
/*                        3 — the audit, before anything opens              */
/* ------------------------------------------------------------------------ */

/**
 * Which audit applies depends on where the previous run stopped, and the posture is read
 * rather than assumed. Auditing for the expected posture is the point of the check; picking
 * the expectation to match whatever was found would make it assert nothing at all — so the
 * two cases where it cannot apply say so, loudly, instead of being quietly satisfied.
 */
const posture = await readPausePosture(connection, addresses);
const userFacing = posture.filter((state) => !state.label.startsWith("Aggregator/"));
const oracleLive = posture.some((state) => state.label.startsWith("Aggregator/") && !state.paused);
const openToUsers = userFacing.filter((state) => !state.paused);

if (openToUsers.length === 0) {
  // Nothing a user can reach is open, so the gate applies in full — whether or not the oracle
  // switch was already lifted by a run that stopped between the two.
  log("");
  log(
    oracleLive
      ? "resuming after the oracle switch was lifted; nothing user-facing is open yet."
      : "verifying the wiring before anything is unpaused...",
  );
  const preReport = await verifyDeployment(connection, addresses, {
    expectPaused: true,
    ...(oracleLive ? { allowLiveOracleUpdate: true } : {}),
    holders,
    config,
  });
  printReport(preReport, log);
  if (!preReport.passed) {
    log("");
    log("Do NOT unpause. Fix the wiring above and re-run — this script resumes.");
    process.exit(1);
  }
} else if (openToUsers.length === userFacing.length && oracleLive) {
  log("");
  log("every operation is already live: this handover has completed before.");
  log("Re-auditing in the live posture instead; the pre-unpause gate no longer applies.");
} else {
  log("");
  log(`WARNING: ${openToUsers.length} of ${userFacing.length} user-facing operations are`);
  log("already live. A previous run was interrupted part-way through the unpause, so the");
  log("pre-unpause audit cannot be applied retroactively — users can already reach some of");
  log("them. Still paused:");
  for (const state of posture.filter((s) => s.paused)) log(`  - ${state.label}`);
  log("The live audit below is the gate. If it fails, PAUSE the deployment and investigate.");
}

/* ------------------------------------------------------------------------ */
/*                          4 — funding and the price                       */
/* ------------------------------------------------------------------------ */

const ZERO = "0x0000000000000000000000000000000000000000";
/** Non-zero only when `deploy.ts` deployed the MockERC20 stand-in, which mints on demand. */
const mockPaymentToken = addresses.paymentToken === ZERO ? undefined : addresses.paymentToken;

const at = async <N extends string>(name: N, address: Address, account?: Address) => {
  const wallet = account === undefined ? undefined : await connection.viem.getWalletClient(account);
  return connection.viem.getContractAt(name, address, {
    client: { public: publicClient, ...(wallet === undefined ? {} : { wallet }) },
  });
};

/**
 * EVERY write below must go through this. `hardhat-viem` returns a plain viem contract, whose
 * `write.*` resolves as soon as the node ACCEPTS the transaction — not when it is mined.
 *
 * On an in-memory chain the distinction does not exist: the transaction is mined on send. On a
 * real network the next call's gas estimate runs against the latest MINED block, which does not
 * yet contain the previous transaction, and reverts on a state that is about to be true. Every
 * write in this script feeds the one after it — unpause then post, mint then approve then
 * deposit — so every one of them is exposed.
 *
 * A local node does not reproduce this even over HTTP, because it estimates against pending
 * state. Only a real chain does.
 */
async function confirm(pending: Promise<`0x${string}`>): Promise<void> {
  await publicClient.waitForTransactionReceipt({ hash: await pending });
}

if (mockPaymentToken !== undefined) {
  log("");
  const usdc = await at("MockERC20", mockPaymentToken, admin);
  const decimals = await usdc.read.decimals();
  const float = parseUnits(process.env.HANDOVER_FLOAT ?? "10000000", decimals);
  const held = await usdc.read.balanceOf([treasury]);

  // Redemptions PULL from the treasury. The approval rode in treasury-actions.json; the
  // balance behind it is the part no batch can carry.
  if (held < float) {
    await confirm(usdc.write.mint([treasury, float - held]));
    log(`funded the treasury with ${formatUnits(float - held, decimals)} mock USDC`);
  } else {
    log(`treasury float already ${formatUnits(held, decimals)} mock USDC`);
  }
}

log("");
const aggregatorAsUnpauser = await at("AdminNavAggregator", addresses.aggregator, unpauser);
if (await aggregatorAsUnpauser.read.isOperationPaused([OP_IDS.ORACLE_UPDATE])) {
  await confirm(aggregatorAsUnpauser.write.unpauseOperation([OP_IDS.ORACLE_UPDATE]));
  log("unpaused: Aggregator/ORACLE_UPDATE");
}

// A fresh post if the cooldown allows one, otherwise the answer written at initialisation.
// Which of the two it is does not matter; that the feed is HEALTHY does, and that is asserted
// below rather than inferred from having made a call.
const aggregator = await at("AdminNavAggregator", addresses.aggregator, feedOperator);
const [, , , updatedAt] = await aggregator.read.latestRoundData();
const cooldown = await aggregator.read.updateCooldown();
const { timestamp: chainNow } = await publicClient.getBlock();

if (chainNow >= updatedAt + cooldown) {
  await confirm(aggregator.write.setRoundDataSafe([config.oracle.initialAnswer]));
  log(`posted NAV ${config.oracle.initialAnswer} (8 decimals)`);
} else {
  log(
    `NAV cooldown has ${updatedAt + cooldown - chainNow}s left; keeping the answer written at ` +
      "initialisation, which is still inside the staleness window",
  );
}

const dataFeed = await at("DataFeed", addresses.dataFeed);
if (!(await dataFeed.read.isHealthy())) {
  throw new Error(
    `DataFeed at ${addresses.dataFeed} is not healthy — getPrice() reverts. Unpausing now ` +
      "would open a product whose every priced path fails. Post a fresh NAV as " +
      `FEED_OPERATOR (${feedOperator}) and re-run.`,
  );
}
log(`DataFeed price: ${await dataFeed.read.getPrice()} (WAD) — healthy`);

/* ------------------------------------------------------------------------ */
/*                             5 — open the product                         */
/* ------------------------------------------------------------------------ */

log("");
log("unpausing user-facing operations...");
await unpauseAll(connection, addresses, unpauser, log);

log("");
const liveReport = await verifyDeployment(connection, addresses, {
  expectPaused: false,
  holders,
  config,
});
printReport(liveReport, log);
if (!liveReport.passed) process.exit(1);

/* ------------------------------------------------------------------------ */
/*                          6 — prove it actually works                     */
/* ------------------------------------------------------------------------ */

if (mockPaymentToken !== undefined && runSmokeTest) {
  log("");
  log("smoke test: mint -> redeem");
  await smokeTest(mockPaymentToken);
}

log("");
log("Handover complete. Contracts:");
for (const [label, address] of Object.entries(addresses)) {
  if (label === "network") continue;
  log(`  ${label.padEnd(19)} ${address}`);
}
log("");
if (liveReport.waivers.length > 0) {
  log("This deployment carries waived checks and is NOT production-grade — see above.");
}

/* ------------------------------------------------------------------------ */

/**
 * Deliberately runs as an account that is NEITHER the treasury nor a role holder: an investor
 * has no privileges, and a smoke test performed by the treasury would move funds from itself
 * to itself and report a zero delta whether or not the vaults worked.
 */
async function smokeTest(paymentToken: Address): Promise<void> {
  const wallets = await connection.viem.getWalletClients();
  const investorWallet = wallets.find(
    (wallet) => getAddress(wallet.account.address) !== getAddress(treasury),
  );
  if (investorWallet === undefined) {
    log("  skipped: every configured key is the treasury, so a redemption delta proves nothing");
    return;
  }
  const investor = getAddress(investorWallet.account.address);

  // Read from the CHAIN rather than the config: the gate can be toggled after deployment by
  // COMPLIANCE_ADMIN, and admitting an account the contract no longer checks would revert on
  // `StatusUnchanged` or waste a transaction on a list nobody reads.
  const compliance = await at("ComplianceRegistry", addresses.complianceRegistry, greenlistOperator);
  if (await compliance.read.greenlistEnabled()) {
    if (!(await compliance.read.isGreenlisted([investor]))) {
      await confirm(compliance.write.setGreenlisted([investor, true]));
      log(`  greenlisted ${investor}`);
    }
  } else {
    log("  greenlist is off — blacklist and sanctions still apply");
  }

  const usdcAsTreasury = await at("MockERC20", paymentToken, treasury);
  const decimals = await usdcAsTreasury.read.decimals();
  const stake = parseUnits("1000", decimals);
  await confirm(usdcAsTreasury.write.mint([investor, stake]));

  const usdc = await at("MockERC20", paymentToken, investor);
  await confirm(usdc.write.approve([addresses.depositVault, 2n ** 256n - 1n]));

  const depositVault = await at("DepositVault", addresses.depositVault, investor);
  await confirm(depositVault.write.depositInstant([paymentToken, stake, 0n]));

  // Read only after the deposit is mined: unconfirmed, this returns the pre-deposit balance
  // and the check below reports a working vault as one that minted nothing.
  const token = await at("WbondToken", addresses.token, investor);
  const minted = await token.read.balanceOf([investor]);
  log(`  minted ${formatUnits(minted, 18)} ${await token.read.symbol()}`);
  if (minted === 0n) throw new Error("smoke test: the deposit minted nothing");

  await confirm(token.write.approve([addresses.redemptionVault, 2n ** 256n - 1n]));
  const redemptionVault = await at("RedemptionVault", addresses.redemptionVault, investor);
  const before = await usdc.read.balanceOf([investor]);
  await confirm(redemptionVault.write.redeemInstant([paymentToken, minted, 0n]));
  const after = await usdc.read.balanceOf([investor]);
  log(`  redeemed for ${formatUnits(after - before, decimals)} mock USDC`);
  if (after <= before) throw new Error("smoke test: the redemption paid nothing");
}
