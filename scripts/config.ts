/**
 * Deployment configuration — the single file a fork edits. Every value is checked against a
 * hard-coded cap in the contracts, listed next to it here; see docs/FORKING.md for the
 * sizing rules behind the numbers that are judgement calls.
 */

export const WAD = 10n ** 18n;

export const FEED_DECIMALS = 8;

export interface PlatformConfig {
  /** Delay on the TimelockController, and on transferring registry admin. */
  timelockDelaySeconds: bigint;

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
