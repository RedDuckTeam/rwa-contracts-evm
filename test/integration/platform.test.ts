import assert from "node:assert/strict";
import { describe, it } from "node:test";

import hre from "hardhat";
import { encodeFunctionData, parseUnits, type Address } from "viem";

import { REFERENCE_CONFIG } from "../../scripts/config.js";
import {
  OP_IDS,
  ROLE_IDS,
  buildGrantBatch,
  defaultOperationalHolders,
  deployPlatform,
  upgradesFor,
} from "../../scripts/lib/deployment.js";
import {
  executeScheduledRefundGrant,
  refundRoleIsGranted,
  replayGrants,
  unpauseAll,
} from "../../scripts/lib/handover.js";
import { verifyDeployment } from "../../scripts/lib/verify.js";

/**
 * End-to-end against the ACTUAL deployment library the scripts use. A hand-built fixture
 * would drift from `scripts/lib/deployment.ts` and quietly stop testing what a client gets.
 */

const connection = await hre.network.create({ network: "hardhatMainnet", chainType: "l1" });
const { networkHelpers, viem } = connection;

const WAD = 10n ** 18n;
const USDC = (amount: string) => parseUnits(amount, 6);

const wallets = await viem.getWalletClients();
const [adminWallet, aliceWallet, bobWallet, pauserWallet, operatorWallet] = wallets;
assert.ok(
  adminWallet && aliceWallet && bobWallet && pauserWallet && operatorWallet,
  "expected at least five wallet clients",
);

const admin = adminWallet.account.address;
const alice = aliceWallet.account.address;
const bob = bobWallet.account.address;

/**
 * Distinct keys for the roles that must never share one. Collapsing them onto the admin is
 * the local-development shape, which verification rejects — testing against it would leave
 * the least-privilege wiring a real fork needs unexercised.
 */
const HOLDERS = {
  ...defaultOperationalHolders(admin),
  pauser: pauserWallet.account.address,
  requestOperator: operatorWallet.account.address,
};

/**
 * Deploys and completes the two-stage handover, exactly as `deploy:local` does.
 * `loadFixture` snapshots the result, so each test restores it rather than re-deploying.
 */
async function deployedPlatform() {
  const { addresses, grants, treasuryActions, holders, config } = await deployPlatform(
    hre,
    connection,
    { admin, deployMockPaymentToken: true, holders: HOLDERS },
  );

  await replayGrants(connection, admin, grants);
  await replayGrants(connection, addresses.treasury, treasuryActions);
  await networkHelpers.time.increase(Number(REFERENCE_CONFIG.timelockDelaySeconds) + 1);
  await executeScheduledRefundGrant(connection, addresses);

  const publicClient = await viem.getPublicClient();
  const at = async <N extends string>(name: N, address: Address, wallet = adminWallet) =>
    viem.getContractAt(name, address, { client: { public: publicClient, wallet } });

  const depositVault = await at("DepositVault", addresses.depositVault);
  const redemptionVault = await at("RedemptionVault", addresses.redemptionVault);
  const usdc = await at("MockERC20", addresses.paymentToken);
  const compliance = await at("ComplianceRegistry", addresses.complianceRegistry);
  const aggregator = await at("AdminNavAggregator", addresses.aggregator);
  const token = await at("WbondToken", addresses.token);

  // Payment-token registration and the provider approval arrive with the grant batch;
  // registering them here as well would hide a batch that had stopped doing it.
  await usdc.write.mint([admin, USDC("10000000")]);

  for (const account of [alice, bob]) {
    await compliance.write.setGreenlisted([account, true]);
    await usdc.write.mint([account, USDC("1000000")]);
  }

  // The price written at aggregator initialisation is older than the staleness window once
  // the timelock delay has elapsed.
  await aggregator.write.unpauseOperation([OP_IDS.ORACLE_UPDATE]);
  await networkHelpers.time.increase(Number(REFERENCE_CONFIG.oracle.updateCooldownSeconds) + 1);
  await aggregator.write.setRoundDataSafe([REFERENCE_CONFIG.oracle.initialAnswer]);

  await unpauseAll(connection, addresses, admin);

  for (const wallet of [aliceWallet, bobWallet]) {
    const theirUsdc = await at("MockERC20", addresses.paymentToken, wallet);
    await theirUsdc.write.approve([addresses.depositVault, 2n ** 256n - 1n]);
    const theirToken = await at("WbondToken", addresses.token, wallet);
    await theirToken.write.approve([addresses.redemptionVault, 2n ** 256n - 1n]);
  }

  return {
    addresses,
    grants,
    holders,
    config,
    publicClient,
    at,
    depositVault,
    redemptionVault,
    usdc,
    compliance,
    aggregator,
    token,
  };
}

describe("two-stage handover", () => {
  /**
   * A deployment that lands but is never wired must not move user funds. Half-finished
   * handovers are the realistic failure, and they do not look broken from the outside.
   */
  it("cannot move funds before the handover completes, and verification says so", async () => {
    const { addresses, grants, treasuryActions, holders, config } = await deployPlatform(
      hre,
      connection,
      { admin, deployMockPaymentToken: true, holders: HOLDERS },
    );

    const beforeHandover = await verifyDeployment(connection, addresses, {
      expectPaused: true,
      holders,
      config,
    });
    const failures = beforeHandover.checks.filter((c) => !c.ok).map((c) => c.name);

    // Operational roles unfilled, critical grant unmatured: the state the audit exists to
    // catch.
    assert.ok(failures.length > 0, "verification passed on an unwired deployment");
    assert.ok(
      failures.some((name) => name.includes("REFUND_VAULT")),
      `expected a REFUND_VAULT failure, got: ${failures.join("; ")}`,
    );

    assert.equal(await refundRoleIsGranted(connection, addresses), false);

    // Replaying the encoded batches rather than re-deriving the calls, and BOTH halves: a
    // handover that skips the treasury's approvals leaves every redemption reverting.
    await replayGrants(connection, admin, grants);
    await replayGrants(connection, addresses.treasury, treasuryActions);
    assert.equal(
      await refundRoleIsGranted(connection, addresses),
      false,
      "the critical grant must NOT take effect before the delay",
    );

    await networkHelpers.time.increase(Number(REFERENCE_CONFIG.timelockDelaySeconds) + 1);
    await executeScheduledRefundGrant(connection, addresses);
    assert.equal(await refundRoleIsGranted(connection, addresses), true);

    const afterHandover = await verifyDeployment(connection, addresses, {
      expectPaused: true,
      holders,
      config,
    });
    assert.ok(
      afterHandover.passed,
      `verification failed after handover: ${afterHandover.checks
        .filter((c) => !c.ok)
        .map((c) => `${c.name} (${c.detail ?? ""})`)
        .join("; ")}`,
    );
  });

  it("the grant batch is exactly what verification expects", async () => {
    const { addresses, config } = await networkHelpers.loadFixture(deployedPlatform);
    const { multisig: grants, treasury: treasuryActions } = buildGrantBatch(addresses, HOLDERS, config);

    // 11 role grants, the market setup (one addPaymentToken per vault plus the provider
    // approval, per token), then exactly one SCHEDULE for the critical grant.
    const roleGrants = grants.filter((g) => g.to === addresses.accessRegistry);
    assert.equal(roleGrants.length, 11);

    const scheduled = grants.filter((g) => g.description.includes("SCHEDULE"));
    assert.equal(scheduled.length, 1);
    assert.equal(scheduled[0]?.to, addresses.timelock);
    assert.equal(grants.at(-1), scheduled[0], "the schedule must be last");

    // The market setup is present, or the deployment would be inert once unpaused.
    assert.equal(grants.filter((g) => g.description.startsWith("addPaymentToken")).length, 2);

    // NOT in the multisig batch: an `approve` is authorised by `msg.sender`, so the treasury
    // has to sign it. Locally the two are the same account, which is exactly when folding
    // them together goes unnoticed.
    assert.equal(grants.filter((g) => g.description.startsWith("approve(")).length, 0);
    assert.equal(treasuryActions.length, 1);
    assert.ok(treasuryActions[0]?.description.includes("MUST be sent by the tokensProvider"));
  });

  /// The only configuration in which folding the batches together would be wrong. Every
  /// other test runs with `treasury === admin`, where the assertion passes either way.
  it("keeps the treasury's approvals out of the multisig batch when they differ", async () => {
    const { addresses } = await networkHelpers.loadFixture(deployedPlatform);
    const separateTreasury = bobWallet.account.address;

    const { multisig, treasury } = buildGrantBatch(
      { ...addresses, treasury: separateTreasury },
      HOLDERS,
      { ...REFERENCE_CONFIG, treasury: separateTreasury, paymentTokens: [
        { address: addresses.paymentToken, feeBps: 0n, allowanceWad: 2n ** 256n - 1n },
      ] },
    );

    // Not one approval in the half the multisig signs...
    assert.equal(multisig.filter((g) => g.description.startsWith("approve(")).length, 0);
    // ...and the treasury half names the account that must sign it.
    assert.equal(treasury.length, 1);
    assert.ok(treasury[0]?.description.includes(separateTreasury));

    // Registrations stay with the multisig: they are VAULT_ADMIN calls, not approvals.
    assert.equal(multisig.filter((g) => g.description.startsWith("addPaymentToken")).length, 2);
  });

  /**
   * A testnet rehearsal cannot wait 48h for one grant, so `acceptShortTimelockDelay` lets a
   * shorter delay through. The property under test is that it waives the GATE and not the
   * CHECK: the floor is still measured against the same literal, the failure is still recorded
   * and still reported, and it is the ONLY thing the declaration changes.
   */
  it("waives a short timelock delay without turning it into a pass", async () => {
    const SHORT_DELAY = 10n * 60n;
    const shortConfig = {
      ...REFERENCE_CONFIG,
      timelockDelaySeconds: SHORT_DELAY,
      acceptShortTimelockDelay: true,
    };

    const { addresses, grants, treasuryActions, holders, config } = await deployPlatform(
      hre,
      connection,
      { admin, deployMockPaymentToken: true, holders: HOLDERS, config: shortConfig },
    );

    await replayGrants(connection, admin, grants);
    await replayGrants(connection, addresses.treasury, treasuryActions);
    await networkHelpers.time.increase(Number(SHORT_DELAY) + 1);
    await executeScheduledRefundGrant(connection, addresses);

    const declared = await verifyDeployment(connection, addresses, {
      expectPaused: true,
      holders,
      config,
    });

    const FLOOR = "timelock minDelay is at least the 48h the trust model assumes";
    const floorCheck = declared.checks.find((c) => c.name === FLOOR);
    assert.ok(floorCheck, "the 48h floor is no longer checked at all");
    assert.equal(floorCheck.ok, false, "the floor check must still FAIL, not silently pass");
    assert.equal(floorCheck.waived, true);
    assert.deepEqual(declared.waivers, [FLOOR]);
    assert.ok(declared.passed, "a declared deviation must not block the handover");

    // The mutation: the SAME chain state, audited without the declaration. If this still
    // passed, the assertions above would be describing a check that cannot fail either way.
    const undeclared = await verifyDeployment(connection, addresses, {
      expectPaused: true,
      holders,
      config: { ...config, acceptShortTimelockDelay: false },
    });
    assert.equal(undeclared.passed, false);
    assert.deepEqual(
      undeclared.checks.filter((c) => !c.ok).map((c) => c.name),
      [FLOOR],
      "the declaration must change the verdict on the floor and nothing else",
    );

    // And the deployment it produced is otherwise a correct one: the delay the registry
    // enforces is the delay the timelock enforces, whatever that number is.
    const registryDelay = declared.checks.find((c) =>
      c.name.startsWith("admin-transfer delay equals"),
    );
    assert.equal(registryDelay?.ok, true, registryDelay?.detail);
  });

  it("passes verification in the live posture once unpaused", async () => {
    const fixture = await networkHelpers.loadFixture(deployedPlatform);
    const { addresses } = fixture;
    const { holders, config } = fixture;
    const report = await verifyDeployment(connection, addresses, {
      expectPaused: false,
      holders,
      config,
    });
    assert.ok(
      report.passed,
      report.checks.filter((c) => !c.ok).map((c) => c.name).join("; "),
    );
  });
});

describe("investor lifecycle", () => {
  it("runs deposit, transfer and redemption end to end", async () => {
    const { depositVault, redemptionVault, usdc, token, at, addresses } =
      await networkHelpers.loadFixture(deployedPlatform);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    await aliceDeposit.write.depositInstant([addresses.paymentToken, USDC("10000"), 0n]);

    // 1% fee at NAV 1.00.
    assert.equal(await token.read.balanceOf([alice]), 9_900n * WAD);
    assert.equal(await usdc.read.balanceOf([await depositVault.read.feeReceiver()]) > 0n, true);

    // Transfers between holders are free — the greenlist gates issuance only.
    const aliceToken = await at("WbondToken", addresses.token, aliceWallet);
    await aliceToken.write.transfer([bob, 900n * WAD]);
    assert.equal(await token.read.balanceOf([bob]), 900n * WAD);

    const aliceRedeem = await at("RedemptionVault", addresses.redemptionVault, aliceWallet);
    const before = await usdc.read.balanceOf([alice]);
    await aliceRedeem.write.redeemInstant([addresses.paymentToken, 9_000n * WAD, 0n]);
    assert.ok((await usdc.read.balanceOf([alice])) > before);
  });

  it("prices a request against a NAV that moved after submission", async () => {
    const { at, addresses, aggregator, usdc } = await networkHelpers.loadFixture(deployedPlatform);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    await aliceDeposit.write.depositRequest([addresses.paymentToken, USDC("10000"), 0n]);

    await networkHelpers.time.increase(Number(REFERENCE_CONFIG.oracle.updateCooldownSeconds) + 1);
    await aggregator.write.setRoundDataSafe([101000000n]); // NAV 1.01

    const depositVault = await at("DepositVault", addresses.depositVault, operatorWallet);
    await depositVault.write.approveDepositRequest([1n, 101n * 10n ** 16n]);

    const token = await at("WbondToken", addresses.token);
    // 9 900 USDC of body at 1.01 -> ~9 801 wBOND
    const minted = await token.read.balanceOf([alice]);
    assert.ok(minted > 9_800n * WAD && minted < 9_802n * WAD, `minted ${minted}`);
    assert.equal(await usdc.read.balanceOf([addresses.depositVault]), 0n);
  });
});

describe("exits survive every fail-closed window", () => {
  /**
   * The central claim: fail-closed on entry, fail-open on exit. Each of these conditions
   * blocks new business, and none may trap an unresolved request.
   */
  it("cancels a redemption while transfers are paused and the owner is blacklisted", async () => {
    const { at, addresses, token, compliance } = await networkHelpers.loadFixture(deployedPlatform);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    await aliceDeposit.write.depositInstant([addresses.paymentToken, USDC("10000"), 0n]);

    const aliceRedeem = await at("RedemptionVault", addresses.redemptionVault, aliceWallet);
    await aliceRedeem.write.redeemRequest([addresses.paymentToken, 5_000n * WAD, 0n]);
    assert.equal(await token.read.balanceOf([addresses.redemptionVault]), 5_000n * WAD);

    // Everything that could strand the escrow, applied at once.
    const tokenAsPauser = await at("WbondToken", addresses.token, pauserWallet);
    await tokenAsPauser.write.pauseOperation([OP_IDS.TRANSFER]);
    await compliance.write.setBlacklisted([alice, true]);

    const balanceBefore = await token.read.balanceOf([alice]);
    await aliceRedeem.write.cancelRequest([1n]);

    assert.equal(await token.read.balanceOf([alice]), balanceBefore + 5_000n * WAD);
    assert.equal(await token.read.balanceOf([addresses.redemptionVault]), 0n);
  });

  it("rejects a deposit request while the feed is stale", async () => {
    const { at, addresses, usdc, depositVault } = await networkHelpers.loadFixture(deployedPlatform);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    const before = await usdc.read.balanceOf([alice]);
    await aliceDeposit.write.depositRequest([addresses.paymentToken, USDC("10000"), 0n]);

    await networkHelpers.time.increase(Number(REFERENCE_CONFIG.oracle.healthyDiffSeconds) + 1);

    const asOperator = await at("DepositVault", addresses.depositVault, operatorWallet);

    // Approval needs a price and is therefore impossible...
    await assert.rejects(() => asOperator.write.approveDepositRequest([1n, WAD]));

    // ...but the operator can still unwind the request. Rejection needs no price.
    await asOperator.write.rejectRequest([1n]);
    assert.equal(await usdc.read.balanceOf([alice]), before);
  });

  it("blocks new business while the feed is stale", async () => {
    const { at, addresses } = await networkHelpers.loadFixture(deployedPlatform);
    await networkHelpers.time.increase(Number(REFERENCE_CONFIG.oracle.healthyDiffSeconds) + 1);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    await assert.rejects(() =>
      aliceDeposit.write.depositInstant([addresses.paymentToken, USDC("10000"), 0n]),
    );
  });
});

describe("compliance is consistent across the deployment", () => {
  /**
   * Token and vaults read the SAME registry, so one blacklist entry must stop both. A
   * split-brain is a compliance failure no individual contract test would catch.
   */
  it("one blacklist entry stops transfers and vault operations alike", async () => {
    const { at, addresses, compliance, token } = await networkHelpers.loadFixture(deployedPlatform);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    await aliceDeposit.write.depositInstant([addresses.paymentToken, USDC("10000"), 0n]);

    await compliance.write.setBlacklisted([alice, true]);

    const aliceToken = await at("WbondToken", addresses.token, aliceWallet);
    await assert.rejects(() => aliceToken.write.transfer([bob, 1n * WAD]), /reverted|Blacklisted/i);
    await assert.rejects(() =>
      aliceDeposit.write.depositInstant([addresses.paymentToken, USDC("1000"), 0n]),
    );

    // And both contracts agree about it through the same source.
    assert.equal(await compliance.read.isBlacklisted([alice]), true);
    assert.equal(await token.read.canSend([alice]), false);
    assert.equal(await compliance.read.isVaultOpAllowed([alice]), false);
  });

  it("replacing the compliance module changes the answer everywhere at once", async () => {
    const { at, addresses, compliance, token } = await networkHelpers.loadFixture(deployedPlatform);
    await compliance.write.setBlacklisted([alice, true]);
    assert.equal(await token.read.canSend([alice]), false);

    const replacement = await upgradesFor(hre, connection);
    const fresh = await replacement.deployProxy(
      "ComplianceRegistry",
      [addresses.accessRegistry, "0x0000000000000000000000000000000000000000", false],
      { kind: "uups" },
    );

    await scheduleAndExecute(addresses.timelock, addresses.token, encodeSetCompliance(fresh.address));
    assert.equal(await token.read.canSend([alice]), true);
  });
});

describe("multi-token support", () => {
  it("accepts a second payment token with different decimals", async () => {
    const { at, addresses, depositVault, redemptionVault } =
      await networkHelpers.loadFixture(deployedPlatform);

    const dai = await viem.deployContract("MockERC20", ["Dai", "DAI", 18]);
    await depositVault.write.addPaymentToken([dai.address, 0n, 2n ** 256n - 1n]);
    await redemptionVault.write.addPaymentToken([dai.address, 0n, 2n ** 256n - 1n]);

    await dai.write.mint([alice, 1_000_000n * WAD]);
    await dai.write.mint([admin, 1_000_000n * WAD]);
    await dai.write.approve([addresses.redemptionVault, 2n ** 256n - 1n]);

    const aliceDai = await at("MockERC20", dai.address, aliceWallet);
    await aliceDai.write.approve([addresses.depositVault, 2n ** 256n - 1n]);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    await aliceDeposit.write.depositInstant([dai.address, 10_000n * WAD, 0n]);

    const token = await at("WbondToken", addresses.token);
    // The same 10 000 units, at 18 decimals rather than 6, must mint the same amount.
    assert.equal(await token.read.balanceOf([alice]), 9_900n * WAD);

    const tokens = await depositVault.read.paymentTokens();
    assert.equal(tokens.length, 2);
  });
});

describe("upgrades preserve state", () => {
  it("upgrades the deposit vault through the timelock without losing a pending request", async () => {
    const { at, addresses, depositVault } = await networkHelpers.loadFixture(deployedPlatform);

    const aliceDeposit = await at("DepositVault", addresses.depositVault, aliceWallet);
    await aliceDeposit.write.depositRequest([addresses.paymentToken, USDC("10000"), 0n]);

    const api = await upgradesFor(hre, connection);
    const nextImpl = await api.deployImplementation("DepositVault", { kind: "uups" });

    await scheduleAndExecute(
      addresses.timelock,
      addresses.depositVault,
      encodeUpgrade(String(nextImpl) as Address),
    );

    const request = await depositVault.read.getRequest([1n]);
    assert.equal(request.amountWad, 10_000n * WAD);
    assert.equal(await depositVault.read.maxSupplyCapWad(), REFERENCE_CONFIG.vault.maxSupplyCapWad);

    // And the restored state is still usable.
    await aliceDeposit.write.cancelRequest([1n]);
  });

  it("rejects an upgrade that would shift storage", async () => {
    const { addresses } = await networkHelpers.loadFixture(deployedPlatform);
    const api = await upgradesFor(hre, connection);

    await assert.rejects(
      () => api.validateUpgrade(addresses.depositVault, "BoxBrokenV2", { kind: "uups" }),
      (error: unknown) => {
        const message = error instanceof Error ? error.message : String(error);
        assert.match(message, /storage layout|upgrade safety|incompatible|namespace/i);
        return true;
      },
    );
  });
});

/* ------------------------------------------------------------------------ */

const EMPTY = `0x${"0".repeat(64)}` as `0x${string}`;

const UPGRADE_ABI = [
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
] as const;

const SET_COMPLIANCE_ABI = [
  {
    type: "function",
    name: "setComplianceRegistry",
    inputs: [{ name: "newRegistry", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

function encodeUpgrade(implementation: Address): `0x${string}` {
  return encodeFunctionData({
    abi: UPGRADE_ABI,
    functionName: "upgradeToAndCall",
    args: [implementation, "0x"],
  });
}

function encodeSetCompliance(registry: Address): `0x${string}` {
  return encodeFunctionData({
    abi: SET_COMPLIANCE_ABI,
    functionName: "setComplianceRegistry",
    args: [registry],
  });
}

/**
 * Takes the timelock address rather than re-reading the fixture: calling `loadFixture` here
 * would RESTORE the snapshot and silently discard whatever the test had just set up.
 */
async function scheduleAndExecute(
  timelockAddress: Address,
  target: Address,
  data: `0x${string}`,
): Promise<void> {
  const publicClient = await viem.getPublicClient();
  const timelock = await viem.getContractAt("RwaTimelockController", timelockAddress, {
    client: { public: publicClient, wallet: adminWallet },
  });

  await timelock.write.schedule([
    target,
    0n,
    data,
    EMPTY,
    EMPTY,
    REFERENCE_CONFIG.timelockDelaySeconds,
  ]);
  await networkHelpers.time.increase(Number(REFERENCE_CONFIG.timelockDelaySeconds) + 1);
  await timelock.write.execute([target, 0n, data, EMPTY, EMPTY]);
}
