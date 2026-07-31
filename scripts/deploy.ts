/**
 * Deploys the platform and writes the artefacts a client multisig needs.
 *
 *   DEPLOY_ADMIN=0x<multisig> pnpm hardhat run scripts/deploy.ts --network sepolia \
 *     --build-profile production
 *   pnpm deploy:local                       (admin = deployer, full local bring-up)
 *
 * PRODUCTION: the deployer never becomes admin. Writes `addresses.json` and a
 * Safe-compatible `grants.json` under `deployments/<network>/`, then stops with everything
 * paused. The multisig executes the batch, returns after the timelock delay for the one
 * SCHEDULED entry, runs `verify-deployment`, and only then unpauses.
 *
 * LOCAL: `DEPLOY_ADMIN` unset means admin = deployer and the script performs the whole
 * handover itself, advancing past the delay, so `deploy:local` yields a live stack.
 */
import hre from "hardhat";
import { getAddress, parseUnits, type Address } from "viem";

import { REFERENCE_CONFIG } from "./config.js";
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

const envAdmin = process.env.DEPLOY_ADMIN;
const isLocalBringUp = envAdmin === undefined;
const admin: Address = isLocalBringUp ? deployer.account.address : getAddress(envAdmin);

// The two-tier model rests on the deployer never holding admin. A one-character paste error
// would collapse both tiers onto one key — and every downstream check compares the chain
// against this same value, so verification would pass.
if (!isLocalBringUp && getAddress(admin) === getAddress(deployer.account.address)) {
  throw new Error(
    `DEPLOY_ADMIN (${admin}) is the deployer. Admin must be the client multisig: the ` +
      "deployer holding it collapses the operational and critical tiers onto one key, and " +
      "no downstream check can detect it — every one of them compares against this value.",
  );
}

// A deployment with no payment tokens is INERT. Said here, before a multisig ceremony and a
// 48h delay are spent discovering it.
if (!isLocalBringUp && REFERENCE_CONFIG.paymentTokens.length === 0) {
  throw new Error(
    "config.paymentTokens is empty. The template ships it empty deliberately — it cannot " +
      "know your chain's stablecoin addresses — but a production deployment must list them, " +
      "or the platform cannot process a single operation once unpaused. " +
      "See docs/FORKING.md §2.3.",
  );
}

log(`network: ${connection.networkName}`);
log(`deployer: ${deployer.account.address}`);
log(`admin:    ${admin}${isLocalBringUp ? "  (local bring-up)" : ""}`);
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
  deployMockPaymentToken: isLocalBringUp,
  ...(localHolders === undefined ? {} : { holders: localHolders }),
  log,
});

log("");
log(`addresses: ${writeAddressBook(addresses)}`);
// The audit reads this back rather than re-importing the config, so it checks the chain
// against what this deployment ACTUALLY used, not the defaults it started from.
log(`record:    ${writeDeploymentRecord({ addresses, holders, config })}`);

const publicClient = await connection.viem.getPublicClient();
const chainId = await publicClient.getChainId();
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
  log("Everything is deployed PAUSED with the greenlist enforced. Next steps:");
  log("  1. execute deployments/<network>/grants.json from the client multisig");
  if (treasuryActions.length > 0) {
    log("     ...and deployments/<network>/treasury-actions.json AS THE TREASURY");
    log(`        (${addresses.treasury}) — an approve is authorised by msg.sender`);
  }
  if (config.paymentTokens.length > 0) {
    log("     (it also registers the payment tokens and the provider approval — the");
    log("      approval entry MUST be sent by the tokensProvider, see its description)");
  }
  log("  2. wait out the timelock delay, then execute the scheduled REFUND_VAULT grant");
  log(`  3. pnpm verify-deployment --network ${connection.networkName}   (must PASS)`);
  log("  4. post NAV, then unpause — unpausing is the LAST step, never the first");
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
log(`advancing past the ${REFERENCE_CONFIG.timelockDelaySeconds}s timelock delay...`);
await connection.networkHelpers.time.increase(Number(REFERENCE_CONFIG.timelockDelaySeconds) + 1);
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
  await connection.networkHelpers.time.increase(Number(REFERENCE_CONFIG.oracle.updateCooldownSeconds) + 1);
  await aggregatorAsUnpauser.write.unpauseOperation([OP_IDS.ORACLE_UPDATE]);
  await aggregator.write.setRoundDataSafe([REFERENCE_CONFIG.oracle.initialAnswer]);
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
