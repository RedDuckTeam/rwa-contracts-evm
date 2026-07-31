# Acceptance criteria — where each one is verified

Every criterion from the specification, mapped to the code that implements it and the test
that proves it. Deviations are listed at the end and detailed in
[`TRUST-MODEL.md`](./TRUST-MODEL.md#4-registered-deviations-from-the-specification).

Reproduce the whole thing with:

```bash
pnpm build && pnpm typecheck && pnpm test
pnpm coverage                                   # line, hardhat
FOUNDRY_PROFILE=coverage pnpm coverage:branch   # branch, forge
pnpm lint && pnpm slither && pnpm size
pnpm deploy:local
```

---

## token

| Criterion | Implementation | Proof |
| --- | --- | --- |
| ERC-20 + ERC-2612 permit, 18 decimals, name/symbol at initialisation | `token/RwaToken.sol`, `products/wbond/WbondToken.sol` | `RwaToken.t.sol` — `test_TokenShape`, `test_PermitGrantsAllowanceWithoutATransaction` |
| ERC-7943 implemented + ERC-165, conformance to the EIP text | `interfaces/IERC7943.sol`, `token/RwaToken.sol` | `test_InterfaceIdMatchesThePublishedValue` asserts the literal `0x3edbb4c4` from the EIP, not a self-referential recomputation |
| Transfers blocked for blacklisted / sanctioned / frozen / paused; fuzz over combinations | `RwaToken._update` | `test_BlacklistBlocksTransfersInBothDirections`, `test_SanctionsBlockTransfers`, `test_SetFrozenTokensBlocksExactlyTheFrozenPortion`, `test_PauseStopsOrdinaryTransfers`, `testFuzz_PredicateAgreesWithActualTransfers` |
| Blacklist cannot be self-cleared (audit lesson H-1) | `ComplianceRegistry.setBlacklisted` refuses `account == msg.sender` on clear | `ComplianceRegistry.t.sol` — `test_RevertWhen_AccountClearsItsOwnBlacklistEntry`, and `test_AnotherOperatorCanClearABlacklistedOperator` shows it does not deadlock |
| Mint/burn only via Minter/Burner, held by the vaults | `RwaToken.mint` / `.burn` | `test_OnlyMinterMintsAndOnlyBurnerBurns`, `test_DepositVaultHasMinterButNotBurner`, `test_RedemptionVaultHasBurnerAndRefundButNotMinter` |

## vaults

| Criterion | Implementation | Proof |
| --- | --- | --- |
| `depositInstant` / `redeemInstant` happy path and every revert path | `DepositVault`, `RedemptionVault` | `DepositVault.t.sol`, `RedemptionVault.t.sol` — greenlist, limits, minimums, pause, unhealthy feed each have a named test |
| Request → approve (within tolerance) / reject / user cancel; all transitions and repeats | `ManageableVault` request machine | `test_ApprovalWithinToleranceSettles`, `test_RevertWhen_OperatorRateIsOutsideTolerance`, `test_RejectReturnsTheEscrowInFull`, `test_CancelReturnsTheEscrowInFull`, `test_RevertWhen_ARequestIsResolvedTwice` |
| Enforcement of fee, daily limit, minimums, first-deposit minimum, supply cap, waivers, per-token fee and allowance | `ManageableVault` + `DepositVault` | `test_InstantDepositMintsAtTheLiveRateAndForwardsFunds`, `test_FirstDepositMinimumAppliesOnceThenRelaxes`, `test_RevertWhen_DailyLimitIsExhausted`, `test_RevertWhen_SupplyCapWouldBeExceeded`, `test_InstantDepositHonoursAFeeWaiver`, `test_PerTokenFeeStacksOnTopOfTheVaultFee`, `test_RevertWhen_TokenAllowanceIsExhausted` |
| Fuzz over 6↔18 decimal conversions; balance-delta against fee-on-transfer; reentrancy | `libraries/DecimalsConverter.sol`, `_pullPaymentToken`, `ReentrancyGuardTransient` | `DecimalsConverter.t.sol` (round-trip and ceiling-semantics fuzz), `test_FeeOnTransferTokenIsCreditedByActualDelta`, `test_ReentrantPaymentTokenIsRejected`, `test_RevertWhen_PaymentTokenDeclaresZeroDecimals` |
| Funds leave to `tokensReceiver` / `feeReceiver`; the mint/burn boundary holds | `_forward`, `_payOut` | `testFuzz_NothingIsRetainedAndTheSplitIsExact`, `invariant_DepositVaultHoldsExactlyItsOpenEscrow`, `invariant_RedemptionVaultNeverAccumulatesPaymentTokens` |

## access-compliance

| Criterion | Implementation | Proof |
| --- | --- | --- |
| Full role × operation matrix, positive and negative | `access/AccessRegistry.sol`, `Roles.sol` | `AccessRegistry.t.sol` (12 role tests), plus a `RevertWhen_…` negative on every privileged entry point across the suites |
| `AccessControlDefaultAdminRules`: delay and two-step transfer | `AccessRegistry` | `test_AdminTransferRequiresTwoStepsAndTheFullDelay` (asserts that accepting *at* the scheduled instant still fails), `test_AdminTransferCanBeCancelled`, `test_RevertWhen_WrongAccountAcceptsAdminTransfer` |
| Granular pause across six operations; a Pauser role disjoint from operational admin | `pause/OperationPausable.sol`, six opIds in `Roles.sol` | `OperationPausable.t.sol` — `test_PausingOneOperationLeavesTheOtherLive`, `test_RevertWhen_PauserTriesToUnpause`, `test_RevertWhen_UnpauserTriesToPause`; `test_PausableOperationsPartitionCleanlyAcrossTheDeployment` proves the six partition with no overlap |
| Sanctions gate consults the oracle and blocks sanctioned parties | `ComplianceRegistry` gas-capped `staticcall` | `test_SanctionedAccountIsRefusedEverywhere`, `test_RevertingOracleStopsMoneyPathsButNotViewPaths`, `test_GasBombOracleIsContainedByTheStipend`, `test_NonContractOracleCountsAsUnavailable` |

## oracle

| Criterion | Implementation | Proof |
| --- | --- | --- |
| DataFeed rejects stale, out-of-bounds, zero and negative prices | `oracle/DataFeed.sol` | `test_RevertWhen_PriceIsStale`, `test_RevertWhen_AnswerIsZeroOrNegative`, `test_RevertWhen_PriceLeavesTheWadBand`, `testFuzz_PriceIsEitherInBandOrRejected` |
| Aggregator: reverts past the 1% deviation and inside the 1h cooldown; emergency path works; posting is role-gated | `oracle/AdminNavAggregator.sol` | `test_RevertWhen_DeviationExceedsTheCap`, `test_RevertWhen_CooldownHasNotElapsed`, `test_AdminBypassesDeviationAndCooldown`, `test_RevertWhen_EmergencyPostLeavesTheHardBounds`, `test_RevertWhen_OperatorUsesTheEmergencyPath` |
| Vault operations stop automatically on an unhealthy feed | vaults call `IDataFeed.getPrice()` | `DepositVault.t.sol` — `test_RevertWhen_FeedIsUnhealthy`; integration — `blocks new business while the feed is stale` |

## whitelabel-deploy

| Criterion | Implementation | Proof |
| --- | --- | --- |
| One command brings the full stack up on EDR with the roles wired | `scripts/deploy.ts` | `pnpm deploy:local` — deploys, replays the grant batch, waits out the timelock, verifies, posts NAV, unpauses, and runs a mint→redeem smoke test |
| Upgrade script passes storage-safety validation; an incompatible layout is rejected | `scripts/upgrade.ts` | `test/upgrades.test.ts`, and integration — `rejects an upgrade that would shift storage` |
| `docs/FORKING.md` covers names, parameters, networks, keys and a security checklist | [`FORKING.md`](./FORKING.md) | — |
| UUPS with `_authorizeUpgrade` behind the timelock role, `_disableInitializers()` in constructors | every UUPS contract | a `RevertWhen_NonUpgraderUpgrades…` and a `Timelock…` test per contract; `verify-deployment` probes all seven implementations with their REAL initializer ABIs and accepts only `InvalidInitialization` as proof |
| Deployment verification is a real gate | `scripts/lib/verify.ts` | exact role membership (operational tier included), role-separation rules, the timelock's own configuration, and a config linter covering wiring pointers, receivers, the greenlist posture, the cross-unit bound consistency and payment-token registration |

## testing-qa

| Criterion | Status |
| --- | --- |
| `pnpm test` green across both layers | 301 passing (284 solidity + 17 nodejs) |
| 100% line and branch on the core contracts | 100% line (604/604) and 100% branch (93/93) on `contracts/{access,compliance,libraries,oracle,pause,token,vaults}/**` |
| Invariants: supply accounting, no stuck escrow, daily limits unbreakable | 6 invariants at 64 runs × 2048 calls, 0 reverts; the handler drives compliance, pauses, the awkward stablecoin and the sweep path, and an `afterInvariant` guard requires that money actually moved |
| solhint 0 errors; Slither 0 high/medium; every contract under 24 576 B | 0 / 0 / largest is DepositVault at ~17.2 kB on the production profile |
| Gas snapshot committed; CI runs build, test, coverage, lint and Slither | `gas-snapshot.json`, `.github/workflows/ci.yml` |
| `tsconfig` strict; build and typecheck clean | `strict` + `noUncheckedIndexedAccess`; both clean |

---

## What the numbers do and do not mean

**"100% branch" is a coarse metric.** `forge coverage` counts 93 branches across ~604
lines. It counts each `if` once and does not decompose `||` / `&&`, so a three-operand
condition like `_setReceivers`' zero-address guard registers as a single branch. Full branch
coverage here means every conditional was taken both ways at least once — not that every
combination of sub-conditions was. Where combinations matter, they are covered explicitly
instead: `testFuzz_PredicateAgreesWithActualTransfers` sweeps all sixteen states of the four
token gates, and `testFuzz_PredicateAgreesWithTheRevertingCheck` does the same for compliance.

**Coverage is a floor, not the argument.** The suite's real weight is in the behavioural
assertions — expected values derived independently and written down, exact-selector reverts
with arguments, and an invariant handler that drives compliance, pauses, the awkward
stablecoin and the sweep path. Two findings in review were tests that held 100% coverage
while being unable to fail; both were rewritten rather than patched.

**Mutation testing is the natural next step** and is not part of v1. It would have caught
both of those directly.

---

## Registered deviations

Five, each deliberate and each covered by a test. Full reasoning in
[`TRUST-MODEL.md` §4](./TRUST-MODEL.md#4-registered-deviations-from-the-specification).

1. **Branch coverage comes from Foundry, not Hardhat.** Hardhat 3 / EDR emits no branch
   data. Foundry is a development-only dependency used for this metric and for Slither.
2. **Under an `OP_TRANSFER` pause, `canSend` reports `false` while `refundFromVault` still
   succeeds** — the ERC-7943 predicates describe the ordinary transfer path, and the
   privileged refund is by construction not that path.
3. **The daily limit is a UTC calendar bucket, not a rolling window**, so a rolling 24h
   window can see up to 2×. Asserted by `test_CalendarBucketAllowsUpTo2xInARolling24hWindow`
   and turned into a sizing rule in `FORKING.md` §2.2.
4. **Per-product role namespacing was removed** — an artefact of a different architecture.
   The virtual getters remain, and a multi-product fork must override the vault-bound ones.
5. **A fifth terminal request status, `Swept`, was added** for the emergency sweep, so a
   swept request can never be mistaken for an ordinary cancellation.

## Out of scope, as specified

Non-fungible RWA · ERC-3643 / ONCHAINID · ERC-7540 / 7575 vault interfaces · fiat
redemption · liquidity swapper · cross-chain · mass-deployment factory · a live canonical
deployment · off-chain operations · on-chain management and performance fees.
