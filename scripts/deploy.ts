/**
 * Deploys the platform and writes the artefacts a client multisig needs.
 *
 *   DEPLOY_ADMIN=0x<admin> pnpm deploy:sepolia
 *   pnpm deploy:local                       (admin = deployer, full local bring-up)
 *
 * PRODUCTION: the deployer never becomes admin. Writes `addresses.json` and a
 * Safe-compatible `grants.json` under `deployments/<network>/`, then stops with everything
 * paused. The multisig executes the batch, returns after the timelock delay for the one
 * SCHEDULED entry, runs `verify-deployment`, and only then unpauses. `scripts/handover.ts`
 * drives that same sequence when the admin's key is available locally.
 *
 * LOCAL: `DEPLOY_ADMIN` unset means admin = deployer and the script performs the whole
 * handover itself, advancing past the delay, so `deploy:local` yields a live stack.
 *
 * Environment:
 *   DEPLOY_ADMIN                 the admin address. Optional when the network configures a
 *                                second account, which is then used. Never the deployer.
 *   DEPLOY_MOCK_PAYMENT_TOKEN=1  deploy a 6-decimal MockERC20 as the payment asset and
 *                                register it. Testnets only — it mints on demand.
 */
import hre from "hardhat";
import { getAddress, parseUnits, type Address } from "viem";

import { assertConfigIsDeployable, configForNetwork } from "./config.js";
import {
  OP_IDS,
  defaultOperationalHolders,
  deployPlatform,
  writeAddressBook,
  writeDeploymentRecord,
  writeGrantBatch,
} from "./lib/deployment.js";
import {
  executeScheduledRefundGrant,
  replayGrants,
  unpauseAll,
} from "./lib/handover.js";
import { printReport, verifyDeployment } from "./lib/verify.js";

const log = (message: string) => console.log(message);

const connection = await hre.network.getOrCreate();
const wallets = await connection.viem.getWalletClients();
const [deployerWallet] = wallets;
if (deployerWallet === undefined) throw new Error("no wallet client available");
// Re-bound non-optional so the narrowing survives into the hoisted helpers below.
const deployer = deployerWallet;

function requireWallet(index: number, label: string): `0x${string}` {
  const wallet = wallets[index];
  if (wallet === undefined) {
    throw new Error(`local bring-up needs wallet #${index} for ${label}`);
  }
  return wallet.account.address;
}

/**
 * The local bring-up hands the platform to the deployer and fast-forwards the timelock, which
 * only an in-memory chain can do. Gating it on the NETWORK and not merely on `DEPLOY_ADMIN`
 * being unset is what stops a forgotten variable from selecting it on a real chain — where it
 * would deploy a live system owned by the deployer key before failing on `time.increase`.
 */
const EPHEMERAL_NETWORK = /^(default|hardhat.*)$/;
const isEphemeralNetwork = EPHEMERAL_NETWORK.test(connection.networkName);

// Named explicitly, or taken from the second configured account — the two-key shape
// `scripts/handover.ts` needs. Never inferred on an ephemeral chain, where "admin = deployer"
// is the whole point.
const envAdmin = process.env.DEPLOY_ADMIN;
const configuredAdmin = isEphemeralNetwork ? undefined : wallets[1]?.account.address;
const resolvedAdmin = envAdmin ?? configuredAdmin;

if (!isEphemeralNetwork && resolvedAdmin === undefined) {
  throw new Error(
    `No admin for "${connection.networkName}". The deployer must never end up holding ` +
      "DEFAULT_ADMIN, so the admin has to be named: set DEPLOY_ADMIN=0x<address>, or " +
      "configure a second account for the network in hardhat.config.ts and it will be used. " +
      "See docs/SEPOLIA.md §1.",
  );
}

const isLocalBringUp = resolvedAdmin === undefined;
const admin: Address = isLocalBringUp ? deployer.account.address : getAddress(resolvedAdmin);

// Per-network, so a testnet's parameters never overwrite the production reference values that
// `deploy:local` and CI assert against.
const platformConfig = configForNetwork(connection.networkName);
assertConfigIsDeployable(platformConfig, connection.networkName);

/**
 * A 6-decimal MockERC20 stands in for a stablecoin. Implied by the local bring-up; on a
 * persistent network it is opt-in, because minting rights over the payment asset are exactly
 * what a production deployment must not have.
 */
const deployMockPaymentToken = isLocalBringUp || process.env.DEPLOY_MOCK_PAYMENT_TOKEN === "1";

// The two-tier model rests on the deployer never holding admin. A one-character paste error
// would collapse both tiers onto one key — and every downstream check compares the chain
// against this same value, so verification would pass.
if (!isLocalBringUp && getAddress(admin) === getAddress(deployer.account.address)) {
  throw new Error(
    `The admin (${admin}) is the deployer. Admin must be a separate account: the deployer ` +
      "holding it collapses the operational and critical tiers onto one key, and no " +
      "downstream check can detect it — every one of them compares against this value.",
  );
}

// A deployment with no payment tokens is INERT. Said here, before a multisig ceremony and a
// timelock delay are spent discovering it. The mock counts: `deployPlatform` appends it to the
// effective configuration, so a bring-up that deploys one is not inert.
if (!deployMockPaymentToken && platformConfig.paymentTokens.length === 0) {
  throw new Error(
    "config.paymentTokens is empty. The template ships it empty deliberately — it cannot " +
      "know your chain's stablecoin addresses — but a production deployment must list them, " +
      "or the platform cannot process a single operation once unpaused. " +
      "See docs/FORKING.md §2.3. On a testnet, DEPLOY_MOCK_PAYMENT_TOKEN=1 deploys one.",
  );
}

log(`network:  ${connection.networkName}`);
log(`deployer: ${deployer.account.address}`);
log(`admin:    ${admin}${isLocalBringUp ? "  (local bring-up)" : ""}`);
log(`timelock: ${platformConfig.timelockDelaySeconds}s`);
if (platformConfig.acceptShortTimelockDelay === true) {
  log("          ^ BELOW the 48h production floor — declared testnet deviation");
}
log("");

// Distinct accounts even locally: collapsing them onto the admin would leave `deploy:local`
// unable to pass its own audit, and the least-privilege wiring never exercised.
const localHolders = isLocalBringUp
  ? {
      ...defaultOperationalHolders(admin),
      pauser: requireWallet(2, "PAUSER"),
      requestOperator: requireWallet(3, "REQUEST_OPERATOR"),
      feedOperator: requireWallet(4, "FEED_OPERATOR"),
    }
  : undefined;

const { addresses, grants, treasuryActions, holders, config } = await deployPlatform(hre, connection, {
  admin,
  deployMockPaymentToken,
  config: platformConfig,
  ...(localHolders === undefined ? {} : { holders: localHolders }),
  log,
});

log("");
log(`addresses: ${writeAddressBook(addresses)}`);
// The audit reads this back rather than re-importing the config, so it checks the chain
// against what this deployment ACTUALLY used, not the defaults it started from.
const publicClient = await connection.viem.getPublicClient();
const chainId = await publicClient.getChainId();

// chainId and not just the network NAME: `deployments/` is keyed by name, and every later step
// refuses a record whose chain does not match the one it is connected to.
log(`record:    ${writeDeploymentRecord({ addresses, holders, config, chainId })}`);

log(`grants:    ${writeGrantBatch(addresses, chainId, grants)}`);

// Entries the TREASURY must sign, non-empty only when it differs from the admin multisig: an
// `approve` is authorised by `msg.sender`, so folding these into the multisig batch would
// grant an allowance from the wrong account.
if (treasuryActions.length > 0) {
  const path = writeGrantBatch(addresses, chainId, treasuryActions, "treasury-actions.json", {
    name: "RWA platform — treasury actions",
    description:
      `Execute as the tokensProvider (${addresses.treasury}), NOT as the admin multisig. ` +
      "Redemptions pull from this account, so without these approvals every exit reverts.",
  });
  log(`treasury:  ${path}`);
}

if (!isLocalBringUp) {
  log("");
  log(
    "Everything is deployed PAUSED" +
      (config.compliance.greenlistEnabled
        ? " with the greenlist enforced"
        : " (greenlist OFF — blacklist and sanctions still apply)") +
      ". Next steps:",
  );
  log(`  1. execute deployments/${connection.networkName}/grants.json from the admin account`);
  if (treasuryActions.length > 0) {
    log(`     ...and treasury-actions.json AS THE TREASURY (${addresses.treasury})`);
    log("        — an approve is authorised by msg.sender, so the signer matters");
  }
  if (config.paymentTokens.length > 0) {
    log("     (it also registers the payment tokens and the provider approval — the");
    log("      approval entry MUST be sent by the tokensProvider, see its description)");
  }
  log("  2. wait out the timelock delay, then execute the scheduled REFUND_VAULT grant");
  log(`  3. pnpm verify-deployment --network ${connection.networkName}   (must PASS)`);
  log("  4. post NAV, then unpause — unpausing is the LAST step, never the first");
  log("");
  log("  When the admin is an account whose key this repo holds, all four are one command:");
  log(`      pnpm handover --network ${connection.networkName}`);
  log("  A multisig admin does step 1 through the Safe UI and the rest with the same command.");
  process.exit(0);
}

/* ------------------------------------------------------------------------ */
/*                      Local bring-up: the full handover                   */
/* ------------------------------------------------------------------------ */

log("");
log("replaying the grant batch...");
await replayGrants(connection, admin, grants, log);
if (treasuryActions.length > 0) {
  log("replaying the treasury actions...");
  await replayGrants(connection, addresses.treasury, treasuryActions, log);
}

log("");
log(`advancing past the ${config.timelockDelaySeconds}s timelock delay...`);
await connection.networkHelpers.time.increase(Number(config.timelockDelaySeconds) + 1);
await executeScheduledRefundGrant(connection, addresses);
log("  executed: REFUND_VAULT -> RedemptionVault");

log("");
log("verifying the deployment before anything is unpaused...");
const preReport = await verifyDeployment(connection, addresses, {
  expectPaused: true,
  holders,
  config,
});
printReport(preReport, log);
if (!preReport.passed) process.exit(1);

// Bound here and not at the top because only the local path needs it: a production network
// has exactly one key.
const investorWalletMaybe = wallets[1];
if (investorWalletMaybe === undefined) {
  throw new Error("local bring-up needs a second wallet client for the smoke test");
}
// Re-bound so the narrowing reaches the hoisted helpers.
const investorWallet = investorWalletMaybe;

log("");
log("completing local setup...");
await setUpLocalMarket();
await unpauseAll(connection, addresses, admin, log);

log("");
const liveReport = await verifyDeployment(connection, addresses, {
  expectPaused: false,
  holders,
  config,
});
printReport(liveReport, log);
if (!liveReport.passed) process.exit(1);

log("");
log("smoke test: mint -> NAV -> redeem");
await smokeTest();

log("");
log("local stack is live.");

/* ------------------------------------------------------------------------ */

async function setUpLocalMarket(): Promise<void> {
  const usdc = await connection.viem.getContractAt("MockERC20", addresses.paymentToken, {
    client: { public: publicClient, wallet: deployer },
  });
  const compliance = await connection.viem.getContractAt(
    "ComplianceRegistry",
    addresses.complianceRegistry,
    { client: { public: publicClient, wallet: deployer } },
  );
  // Local bring-up assigns FEED_OPERATOR to a different key than the admin; using the admin
  // here would work only by accident.
  const feedOperatorWallet = wallets[4];
  if (feedOperatorWallet === undefined) throw new Error("missing the local FEED_OPERATOR wallet");
  const aggregator = await connection.viem.getContractAt(
    "AdminNavAggregator",
    addresses.aggregator,
    { client: { public: publicClient, wallet: feedOperatorWallet } },
  );
  const aggregatorAsUnpauser = await connection.viem.getContractAt(
    "AdminNavAggregator",
    addresses.aggregator,
    { client: { public: publicClient, wallet: deployer } },
  );

  // Registration and the provider approval rode in the grant batch and are already replayed;
  // all that is left is funding the treasury float.
  await usdc.write.mint([addresses.treasury, parseUnits("10000000", 6)]);

  // The greenlist starts enforced, so the smoke-test account is admitted the way a real
  // investor would be.
  await compliance.write.setGreenlisted([investorWallet.account.address, true]);

  // The price written at aggregator initialisation is already past the staleness window by
  // the time the timelock delay has elapsed.
  await connection.networkHelpers.time.increase(Number(config.oracle.updateCooldownSeconds) + 1);
  await aggregatorAsUnpauser.write.unpauseOperation([OP_IDS.ORACLE_UPDATE]);
  await aggregator.write.setRoundDataSafe([config.oracle.initialAnswer]);
  log("  posted NAV and admitted the smoke-test account");
}

async function smokeTest(): Promise<void> {
  // A DISTINCT investor account: locally the deployer is also the treasury, so redeeming as
  // the deployer would move USDC from itself to itself and report a zero delta.
  const depositVault = await connection.viem.getContractAt("DepositVault", addresses.depositVault, {
    client: { public: publicClient, wallet: investorWallet },
  });
  const redemptionVault = await connection.viem.getContractAt(
    "RedemptionVault",
    addresses.redemptionVault,
    { client: { public: publicClient, wallet: investorWallet } },
  );
  const usdc = await connection.viem.getContractAt("MockERC20", addresses.paymentToken, {
    client: { public: publicClient, wallet: investorWallet },
  });
  const token = await connection.viem.getContractAt("WbondToken", addresses.token, {
    client: { public: publicClient, wallet: investorWallet },
  });

  const investor = investorWallet.account.address;
  await usdc.write.mint([investor, parseUnits("100000", 6)]);
  await usdc.write.approve([addresses.depositVault, 2n ** 256n - 1n]);

  await depositVault.write.depositInstant([addresses.paymentToken, parseUnits("10000", 6), 0n]);
  const minted = await token.read.balanceOf([investor]);
  log(`  minted ${minted} wBOND`);
  if (minted === 0n) throw new Error("smoke test: nothing minted");

  await token.write.approve([addresses.redemptionVault, 2n ** 256n - 1n]);
  const before = await usdc.read.balanceOf([investor]);
  await redemptionVault.write.redeemInstant([addresses.paymentToken, minted, 0n]);
  const after = await usdc.read.balanceOf([investor]);
  log(`  redeemed for ${after - before} USDC`);
  if (after <= before) throw new Error("smoke test: redemption paid nothing");
}
