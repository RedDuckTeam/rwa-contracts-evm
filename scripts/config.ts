/**
 * Deployment configuration — the single file a fork edits. Every value is checked against a
 * hard-coded cap in the contracts, listed next to it here; see docs/FORKING.md for the
 * sizing rules behind the numbers that are judgement calls.
 */

export const WAD = 10n ** 18n;

export const FEED_DECIMALS = 8;

/**
 * The delay docs/TRUST-MODEL.md quantifies the blast radius of a compromised multisig against,
 * and the default of `AccessRegistry.DEFAULT_ADMIN_TRANSFER_DELAY`. Written here as a literal
 * rather than read from the chain on purpose: an audit that took its own floor from the
 * deployment it audits could not detect a deployment that lowered both.
 */
export const PRODUCTION_TIMELOCK_DELAY_SECONDS = 48n * 60n * 60n;

export interface PlatformConfig {
  /**
   * Delay on the TimelockController, and on transferring registry admin. The two are the same
   * number by construction — `AccessRegistry.initialize` takes it as a parameter — and
   * `verify-deployment` asserts the equality on-chain.
   *
   * PRODUCTION: 48h. Anything lower is a deliberate deviation from the published trust model
   * and must be declared with {PlatformConfig.acceptShortTimelockDelay}.
   */
  timelockDelaySeconds: bigint;

  /**
   * Set ONLY on a testnet, and only together with a `timelockDelaySeconds` below 48h. It does
   * not change any check's outcome — the audit still reads the delay off the chain and
   * compares it to the 48h floor — it changes whether that comparison is fatal, and the
   * report prints the deviation either way. `deploy.ts` refuses a short delay without it, so
   * the shortcut cannot be taken by accident.
   */
  acceptShortTimelockDelay?: boolean;

  oracle: {
    /** In feed decimals. Must already sit inside the hard bounds. */
    initialAnswer: bigint;
    /**
     * A LAST-RESORT BREAKER, not a working corridor: a NAV move beyond these cannot be
     * posted until they are widened through the timelock, so roughly 48h of fail-closed
     * operation. Narrowing later is cheap; widening during a crisis costs the full delay.
     */
    minAnswer: bigint;
    maxAnswer: bigint;
    /** Cap: MAX_DEVIATION_BPS = 2000. */
    deviationBps: bigint;
    /** Cap: MAX_UPDATE_COOLDOWN = 7 days. */
    updateCooldownSeconds: bigint;
    /** Cap: MAX_HEALTHY_DIFF = 30 days. */
    healthyDiffSeconds: bigint;
    /** Must describe the same range as the aggregator's bounds, in WAD. */
    minPriceWad: bigint;
    maxPriceWad: bigint;
  };

  vault: {
    /** Cap: MAX_INSTANT_FEE_BPS = 500. */
    instantFeeBps: bigint;
    /**
     * The bucket is a UTC CALENDAR day, not a rolling window, so a rolling 24h window can
     * see up to 2x this figure. Size against the 2x.
     */
    instantDailyLimitWad: bigint;
    /** Cap: MAX_MIN_AMOUNT_WAD = 100_000e18. */
    minAmountWad: bigint;
    /** Must be >= minAmountWad. */
    minFirstAmountWad: bigint;
    /** Cap: MAX_VARIATION_TOLERANCE_BPS = 1000. */
    variationToleranceBps: bigint;
    maxSupplyCapWad: bigint;
  };

  compliance: {
    /** Chainalysis-compatible oracle, or the zero address to disable the gate. */
    sanctionsOracle: `0x${string}`;
    /** Production starts `true` (fail-closed). */
    greenlistEnabled: boolean;
  };

  /**
   * Where deposits land and redemptions are funded from; defaults to the admin multisig.
   * Point it elsewhere and the provider approval can no longer ride in the multisig's grant
   * batch, because it must be sent by the treasury itself — the deploy script emits it
   * separately.
   *
   * This one value fills `tokensReceiver`, `feeReceiver` AND `blockedFundsReceiver`, which
   * the contracts keep separate. Splitting them afterwards with a timelocked `setReceivers`
   * makes `verify-deployment` report those three checks as failures from then on: the audit
   * is a handover gate against the persisted record, not a continuous monitor.
   */
  treasury?: `0x${string}`;

  /**
   * Registered on both vaults, with the treasury allowance each needs. An empty list makes
   * the deployment INERT — every deposit reverts `TokenNotConfigured` and every redemption
   * reverts on allowance — which `verify-deployment` reports rather than leaving to be
   * discovered after unpausing.
   */
  paymentTokens: {
    address: `0x${string}`;
    /** Surcharge on top of the vault-wide fee. Cap: MAX_TOKEN_FEE_BPS = 500. */
    feeBps: bigint;
    /** Exposure budget in WAD. `type(uint256).max` for unlimited. */
    allowanceWad: bigint;
  }[];

  /**
   * Unset fields fall back to the admin multisig: convenient locally, wrong in production.
   * PAUSER and UNPAUSER sharing a key defeats the circuit breaker; REQUEST_OPERATOR and
   * VAULT_ADMIN sharing one lets the account that moves user funds also set the limits those
   * movements are checked against. See FORKING.md §1.3.
   */
  operationalHolders?: Partial<{
    complianceAdmin: `0x${string}`;
    greenlistOperator: `0x${string}`;
    blacklistOperator: `0x${string}`;
    requestOperator: `0x${string}`;
    vaultAdmin: `0x${string}`;
    feedOperator: `0x${string}`;
    feedAdmin: `0x${string}`;
    pauser: `0x${string}`;
    unpauser: `0x${string}`;
  }>;
}

/** NAV around 1.00 with bounds at 0.50 / 10.00 — deliberately wide, per the breaker rule. */
export const REFERENCE_CONFIG: PlatformConfig = {
  timelockDelaySeconds: 48n * 60n * 60n,

  oracle: {
    initialAnswer: 1_00000000n, // 1.00 at 8 decimals
    minAnswer: 50000000n, // 0.50
    maxAnswer: 10_00000000n, // 10.00
    deviationBps: 100n, // 1%
    updateCooldownSeconds: 60n * 60n, // 1h
    healthyDiffSeconds: 72n * 60n * 60n, // 72h
    minPriceWad: WAD / 2n,
    maxPriceWad: 10n * WAD,
  },

  vault: {
    instantFeeBps: 100n, // 1%
    instantDailyLimitWad: 1_000_000n * WAD,
    minAmountWad: 100n * WAD,
    minFirstAmountWad: 1_000n * WAD,
    variationToleranceBps: 100n, // 1%
    maxSupplyCapWad: 100_000_000n * WAD,
  },

  compliance: {
    sanctionsOracle: "0x0000000000000000000000000000000000000000",
    greenlistEnabled: true,
  },

  // Populated by the local bring-up with a mock USDC. A real fork lists the actual stablecoin
  // addresses for its chain — see FORKING.md §2.3.
  paymentTokens: [],
};

/* ========================================================================== */
/*                        SEPOLIA — THE BLOCK YOU EDIT                        */
/* ========================================================================== */

/**
 * Every address below that still reads {REPLACE_ME} is rejected by
 * {assertConfigIsDeployable} before a single transaction is sent. It is a valid 20-byte
 * address rather than a malformed string so that the failure is a named configuration error
 * and not a hex-parsing one three frames deep in viem.
 */
export const REPLACE_ME = "0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddead" as const;

/**
 * Sepolia rehearsal configuration. Separate from {REFERENCE_CONFIG} on purpose: the reference
 * values are what `deploy:local` and CI assert against, and editing them in place to suit a
 * testnet would turn the production defaults into whatever the last testnet needed.
 *
 * Deviations from {REFERENCE_CONFIG} are marked `TESTNET:` and each says what it costs. Five
 * are here; the sixth is the mock payment token, which is a deploy-time flag rather than a
 * value. docs/SEPOLIA.md §5 lists all six together.
 */
export const SEPOLIA_CONFIG: PlatformConfig = {
  // TESTNET: 5 minutes instead of 48h. This is the ONLY reason a Sepolia bring-up finishes in
  // one sitting: the REFUND_VAULT grant is scheduled through the TimelockController and cannot
  // be executed before it matures. Raise it to rehearse a realistic wait; `scripts/handover.ts`
  // waits out whatever it is. It also becomes the registry's admin-transfer delay.
  timelockDelaySeconds: 5n * 60n,
  // Required by deploy.ts whenever the delay is under 48h. Drop this line for a production
  // fork and the deploy refuses to start rather than producing a deployment that reads as
  // audited when it is not.
  acceptShortTimelockDelay: true,

  oracle: {
    initialAnswer: 1_00000000n, // 1.00 at 8 decimals
    minAnswer: 50000000n, // 0.50
    maxAnswer: 10_00000000n, // 10.00
    deviationBps: 100n, // 1%
    // TESTNET: 5 minutes instead of 1h, so a NAV post is testable shortly after the bring-up
    // rather than an hour later. The cooldown runs from the answer written at initialisation.
    updateCooldownSeconds: 5n * 60n,
    // TESTNET: 30 days — MAX_HEALTHY_DIFF, the largest the contract accepts — instead of 72h,
    // so a testnet deployment does not go dead because nobody posted NAV over a long weekend.
    // FEED_ADMIN can change it at any time without a timelock proposal; see
    // {DataFeed.setHealthyDiff}. In production this must exceed the NAV posting interval with
    // room for one missed post, and no more: it is how long a stale price stays tradeable.
    healthyDiffSeconds: 30n * 24n * 60n * 60n,
    minPriceWad: WAD / 2n,
    maxPriceWad: 10n * WAD,
  },

  vault: {
    instantFeeBps: 100n, // 1%
    instantDailyLimitWad: 1_000_000n * WAD,
    // TESTNET: 10 / 100 instead of 100 / 1 000, so a first deposit does not need four figures
    // of mock stablecoin. Both stay non-zero — a minimum of zero is a guard that never fires.
    minAmountWad: 10n * WAD,
    minFirstAmountWad: 100n * WAD,
    variationToleranceBps: 100n, // 1%
    maxSupplyCapWad: 100_000_000n * WAD,
  },

  compliance: {
    // Chainalysis publishes no sanctions oracle on Sepolia. Zero disables the gate; the
    // blacklist below is unaffected and stays enforced.
    sanctionsOracle: "0x0000000000000000000000000000000000000000",
    // TESTNET: blacklist-only. The greenlist is an ALLOWLIST on vault operations — with it on,
    // every wallet must be admitted one at a time before it can deposit, which is the correct
    // fail-closed posture for a regulated product and pure friction for a testnet.
    //
    // Turning it off does NOT weaken the blacklist: `_checkParty` runs on every transfer and
    // every vault operation regardless, and so does the sanctions gate. What changes is only
    // that `checkVaultOp` stops additionally requiring membership.
    //
    // Reversible at runtime by COMPLIANCE_ADMIN — `setGreenlistEnabled(true)` — with no
    // redeploy and no timelock. Production ships `true`; see REFERENCE_CONFIG.
    greenlistEnabled: false,
  },

  // Left unset ⇒ the treasury IS the admin account. Keeping them one account is what lets the
  // whole handover run from two keys; set it to a third address and `treasury-actions.json`
  // must be signed by THAT account, and `scripts/handover.ts` needs its key too.
  // treasury: "0x...",

  // Left empty on purpose: with DEPLOY_MOCK_PAYMENT_TOKEN=1 the deploy script deploys a
  // 6-decimal MockERC20 and appends it here itself. To use a real Sepolia ERC-20 instead, drop
  // the flag and list it — e.g. Circle's test USDC, 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238:
  //   { address: "0x1c7D...", feeBps: 0n, allowanceWad: 2n ** 256n - 1n }
  // feeBps caps at MAX_TOKEN_FEE_BPS = 500. allowanceWad is the exposure budget in WAD.
  paymentTokens: [],

  operationalHolders: {
    // The two roles that MUST NOT collapse onto the admin, enforced by `assertRoleSeparation`
    // at deploy time:
    //   pauser         ≠ unpauser        — a key that can both stop and restart the system is
    //                                      not a circuit breaker.
    //   requestOperator ≠ vaultAdmin     — the account that moves user funds must not also set
    //                                      the limits those movements are checked against.
    //
    // Every other operational role is left unset and falls back to the admin. On a testnet
    // that is the point: fewer keys to hold. In production, split them — see FORKING.md §1.3.
    //
    // The deployer address is the natural choice for both: it is a key you already hold, it is
    // never the admin (deploy.ts refuses that outright), and REQUEST_OPERATOR on a key you
    // control is what makes the deposit/redemption REQUEST flows testable at all.
    // `pnpm accounts --network sepolia` prints it.
    // The deployer of the current Sepolia deployment. Replace HERE, never by editing
    // {REPLACE_ME} itself: that constant is the sentinel `assertConfigIsDeployable` compares
    // against, so overwriting it disarms the check for every field at once and turns whatever
    // address you put there into a value the deploy then refuses to accept anywhere else.
    pauser: "0x7dF6F896ad739690Ad3dBe07d9215088027fD9de",
    requestOperator: "0x7dF6F896ad739690Ad3dBe07d9215088027fD9de",

    // VAULT_ADMIN must stay on the admin account for the handover: `grants.json` calls
    // `addPaymentToken`, which is `onlyRegistryRole(vaultAdminRole())` and executes as the
    // admin. `buildGrantBatch` throws if you move it while payment tokens are configured.
    // vaultAdmin: <admin>,
  },
};

/** Per-network configuration. Networks absent here get the production reference values. */
const CONFIG_BY_NETWORK: Record<string, PlatformConfig> = {
  sepolia: SEPOLIA_CONFIG,
};

export function configForNetwork(networkName: string): PlatformConfig {
  return CONFIG_BY_NETWORK[networkName] ?? REFERENCE_CONFIG;
}

/**
 * Fails on a configuration that would deploy but not work, BEFORE any gas is spent. Each check
 * corresponds to a failure that is otherwise discovered after the deployment exists: an
 * unreplaced placeholder produces a role held by an address nobody controls, and a short
 * timelock produces a deployment whose audit reads as a production PASS.
 */
export function assertConfigIsDeployable(config: PlatformConfig, networkName: string): void {
  const placeholders: string[] = [];
  const check = (path: string, value: string | undefined) => {
    if (value !== undefined && value.toLowerCase() === REPLACE_ME) placeholders.push(path);
  };

  check("treasury", config.treasury);
  check("compliance.sanctionsOracle", config.compliance.sanctionsOracle);
  for (const [role, address] of Object.entries(config.operationalHolders ?? {})) {
    check(`operationalHolders.${role}`, address);
  }
  config.paymentTokens.forEach((token, index) => {
    check(`paymentTokens[${index}].address`, token.address);
  });

  if (placeholders.length > 0) {
    throw new Error(
      `scripts/config.ts still holds the REPLACE_ME placeholder at: ${placeholders.join(", ")}. ` +
        `Fill in the real addresses for "${networkName}" — see docs/SEPOLIA.md §2.`,
    );
  }

  if (config.timelockDelaySeconds < PRODUCTION_TIMELOCK_DELAY_SECONDS) {
    if (config.acceptShortTimelockDelay !== true) {
      throw new Error(
        `timelockDelaySeconds is ${config.timelockDelaySeconds}s, below the ` +
          `${PRODUCTION_TIMELOCK_DELAY_SECONDS}s the trust model is written against. ` +
          "It is the entire reaction window against a compromised admin multisig. If this is " +
          "a testnet rehearsal, set `acceptShortTimelockDelay: true` next to it; the audit " +
          "will report the deviation rather than pass silently. Production must not set it.",
      );
    }
  } else if (config.acceptShortTimelockDelay === true) {
    // Left set after raising the delay, it would silently disarm the guard on the next fork.
    throw new Error(
      "acceptShortTimelockDelay is set but timelockDelaySeconds is already at or above the " +
        `${PRODUCTION_TIMELOCK_DELAY_SECONDS}s floor. Remove the declaration.`,
    );
  }
}
