# Forking this template for a client

Read `docs/TRUST-MODEL.md` first. This document turns its conclusions into concrete steps
and configuration rules.

The core contracts are not meant to be edited during onboarding. If you find yourself
changing something under `contracts/access`, `contracts/compliance`, `contracts/oracle`,
`contracts/pause`, `contracts/token` or `contracts/vaults`, stop and check whether one of
the three intended extension points covers it:

1. **`scripts/config.ts`** — every parameter.
2. **A thin product subclass** — see `contracts/products/wbond/WbondToken.sol`, which fixes
   a name and a symbol and contains nothing else.
3. **Replacing the `ComplianceRegistry`** through the timelock — the seam for different
   compliance rules.

---

## 1. Onboarding checklist

### 1.1 Product identity

- [ ] Copy `contracts/products/wbond/` to `contracts/products/<product>/` and rename the
      contract. Change the name and symbol string, nothing else.
- [ ] Update the contract name in `scripts/lib/deployment.ts` (`api.deployProxy("WbondToken", …)`).
- [ ] **Multi-product forks only:** if several products share one `AccessRegistry`,
      override `minterRole()`, `burnerRole()` and `refundVaultRole()` in the product
      subclass with namespaced ids. Skipping this gives product A's vaults live privileges
      over product B's token. There is no runtime check for this — it is your
      responsibility.

### 1.2 Parameters

Every value lives in `scripts/config.ts` and is bounded by a constant in the contracts, so
a typo produces a failed deployment rather than a live misconfiguration. Sizing rules for
the values that are genuine judgement calls are in §2.

- [ ] `timelockDelaySeconds` — 48h default. Lowering it lowers your reaction window;
      see TRUST-MODEL §1.2.
- [ ] `oracle.minAnswer` / `oracle.maxAnswer` — **read §2.1 before touching these.**
- [ ] `oracle.minPriceWad` / `oracle.maxPriceWad` — must describe the **same band** as the
      aggregator bounds, in WAD. The two are checked against each other by
      `test_AggregatorAndFeedBoundsDescribeTheSameBand`; keep that test honest.
- [ ] `oracle.deviationBps`, `oracle.updateCooldownSeconds` — how fast NAV may move.
- [ ] `oracle.healthyDiffSeconds` — must exceed your NAV posting interval with room for a
      missed post, or the feed goes stale during normal operation.
- [ ] `vault.instantDailyLimitWad` — **read §2.2.**
- [ ] `vault.instantFeeBps`, `minAmountWad`, `minFirstAmountWad`, `variationToleranceBps`,
      `maxSupplyCapWad`.
- [ ] `compliance.sanctionsOracle` — the Chainalysis oracle for your chain, or the zero
      address to disable the gate. **Read §2.3.**
- [ ] `compliance.greenlistEnabled` — leave `true`. Starting open is a fail-open start.
- [ ] `treasury` — where deposits land and redemptions are funded from. Defaults to the
      admin multisig. Point it at a separate liquidity desk and the handover grows a second
      batch that the treasury itself must sign; see §3.
- [ ] `operationalHolders` — **required in production.** Leaving it unset collapses all nine
      roles onto the admin, which `deploy.ts` now refuses outright: a batch that provably
      cannot pass its own audit is never written. See §1.3.

### 1.3 Keys and roles

- [ ] `DEPLOY_ADMIN` is the client multisig. **The deployer must never become admin.** The
      deploy script enforces this by passing the multisig as `initialDefaultAdmin`.
- [ ] Split the operational roles across separate keys. `defaultOperationalHolders()` puts
      them all on the admin address for local development; that is a convenience, not a
      recommendation. At minimum: `PAUSER` on a monitoring bot, `FEED_OPERATOR` on the NAV
      bot, `REQUEST_OPERATOR` on the ops team, everything else on the multisig.
- [ ] **Timelock proposer keys are unrecoverable.** Losing them means permanently losing the
      ability to upgrade, to change any guardrail, and to sweep. There is no backdoor and
      none can be added — `renounceRole` on critical roles reverts precisely so the system
      cannot brick itself, but that does not help if the keys are simply gone. Store them
      at the same class as the multisig's own keys.
- [ ] `ENFORCER_ROLE` is granted to nobody by the deployment. Grant it only if the client's
      counsel has confirmed they need confiscation powers, and only through the timelock.

### 1.4 Network

- [ ] Add the target chain to `hardhat.config.ts`.
- [ ] **The chain must support EIP-1153 (transient storage).** The token's refund carve-out
      and `ReentrancyGuardTransient` both depend on it. `evmVersion` is pinned to `cancun`
      for this reason. A chain without it will not merely run slower — the contracts will
      not work.
- [ ] Confirm the payment tokens you intend to accept exist on that chain and read §2.3.

---

## 2. Sizing rules

### 2.1 Hard bounds are a breaker, not a corridor

`oracle.minAnswer` / `maxAnswer` are the last line of defence on NAV. Understand both
directions before choosing them:

- **Too wide** → a compromised `FEED_ADMIN` key can push the posted price a long way from
  reality. This term appears directly in the blast-radius formula (TRUST-MODEL §1.2) and is
  the strongest single lever you have over it.
- **Too narrow** → a legitimate multi-sigma NAV move cannot be posted at all, and every
  price-dependent operation is fail-closed for a full timelock delay (~48h) while you widen
  them.

The asymmetry is the rule: **narrowing later is cheap; widening during a crisis costs the
full delay.** Size for the largest NAV move you would still consider plausible over the
life of the deployment, then verify the resulting radius is acceptable:

```
radius ≈ instantDailyLimitWad × days_until_response × (maxAnswer / expectedNAV − 1)
```

For a low-volatility treasury product, bounds of roughly ±25% around the expected NAV are
usually both comfortable and far safer than the reference ±/×10.

### 2.2 The daily limit is a calendar bucket — size against 2×

`instantDailyLimitWad` is charged against the **UTC calendar day**, not a rolling window.
Spending the full limit late on one day and again early on the next puts **up to 2× the
limit** through a single rolling 24-hour period. This is registered deviation #3 and is
asserted by `test_CalendarBucketAllowsUpTo2xInARolling24hWindow`.

**Rule: decide the maximum you are willing to see move in any 24 hours, then set
`instantDailyLimitWad` to HALF of it.**

The limit applies to instant operations only. Request flows are unbounded by it, because
they are individually approved by a human.

### 2.3 Choosing payment tokens

Every mainstream stablecoin runs its own blacklist, entirely outside this system. When one
refuses a refund, the platform's escape hatch is `sweepBlockedRefund` — a timelocked path
that retries the refund and, only if it fails again, diverts the funds. That is a real
operational burden, not a theoretical one.

- [ ] Prefer tokens with a well-understood freeze policy and a route for contesting it.
- [ ] Confirm decimals. **More than 18 is rejected outright** — the vault will not register
      such a token, because accepting it would make the WAD conversion itself lossy.
- [ ] Confirm whether the token charges a transfer fee. The vaults handle it correctly
      (credit follows the measured balance delta), but the economics are the client's to
      accept.
- [ ] Set a per-token `remainingAllowanceWad` if you want a cap on exposure to any single
      stablecoin. `type(uint256).max` means unlimited.

### 2.4 Optional hardening: `UNPAUSER` behind the timelock

By default `UNPAUSER_ROLE` sits with the multisig, so an incident can be resolved quickly.
A client with a higher assurance requirement can instead grant `UNPAUSER_ROLE` to the
**timelock** for the critical operations. The effect: an attacker who compromises the
multisig cannot lift a pause a monitoring bot applied — they must wait out 48h in the open,
where the pending proposal is visible.

The cost is symmetric: legitimate recovery from a false-positive pause also takes 48h.
Decide deliberately.

---

## 3. Deployment: the two-stage handover

The deployment lands **fully paused** with the greenlist enforced. Nothing can move user
funds until the wiring has been verified. Do not shortcut this.

### Stage 1 — deploy

```bash
DEPLOY_ADMIN=0x<multisig> pnpm hardhat run scripts/deploy.ts \
  --network <network> --build-profile production
```

Produces:

- `deployments/<network>/addresses.json`
- `deployments/<network>/deployment.json` — addresses, role holders and the effective
  configuration. `verify-deployment` reads this rather than the template defaults, so the
  audit checks the chain against what this deployment actually used.
- `deployments/<network>/grants.json` — a Safe Transaction Builder batch for the multisig
- `deployments/<network>/treasury-actions.json` — **only when the treasury is a different
  account from the multisig.** These must be signed BY the treasury: an `approve` is
  authorised by `msg.sender`, so executing them from the multisig would grant an allowance
  from the wrong account. Skip them and every redemption reverts on allowance.
- `.openzeppelin/<network>.json` — the proxy manifest. **Commit it.** It records the storage
  layout of every deployed implementation, and it is what lets `scripts/upgrade.ts` prove a
  future upgrade is safe. Losing it means losing that ability.

  Note that `pnpm deploy:local` produces NO manifest: `hardhat-upgrades` treats in-memory
  development chains as ephemeral and does not persist one. That is expected. The first
  deployment to a real network is where the file appears, and where committing it starts to
  matter.

The deployer holds no privileges at any point.

### Stage 2 — hand over

1. Execute `grants.json` from the multisig. Every entry except the last takes effect
   immediately.
2. **The last entry only SCHEDULES a grant.** `REFUND_VAULT_ROLE` is critical, so it is
   administered by the timelock and cannot be granted directly. Return after the delay and
   execute it. If you skip this, redemption refunds will fail once the system is live.
3. Run the audit — it must PASS:

   ```bash
   pnpm hardhat run scripts/verify-deployment.ts --network <network> --build-profile production
   ```

   It asserts negative facts as well as positive ones: that the RedemptionVault is the
   **only** holder of `REFUND_VAULT_ROLE`, that the DepositVault does **not** hold
   `BURNER_ROLE`, that `ENFORCER_ROLE` is held by nobody, and that no implementation
   contract can still be initialised.

4. **Post NAV before unpausing.** Unpause `OP_ORACLE_UPDATE`, post a fresh price, and only
   then open the user-facing operations. The price written at aggregator initialisation is
   older than the staleness window by the time a real handover completes, so unpausing first
   would open a product whose every priced path reverts.
5. Unpause the remaining operations. **This is the last step, never the first.**
6. Re-run `verify-deployment` with `EXPECT_LIVE=1` to confirm the live posture.

### Recovering an interrupted handover

`unpauseAll` skips anything already live, so re-running it is safe. If the scheduled
`REFUND_VAULT` grant was missed, schedule and execute it separately — the calldata is in
`grants.json` and `scripts/lib/deployment.ts` exposes `refundGrantExecution()` for it.

### Migrating a live deployment

If a fork needs to move to a new `AccessRegistry` — which the design does not otherwise
allow, since the timelock address has no setter — the route is an upgrade of every
consuming contract, proposed through the existing timelock. Plan for one timelock delay per
proposal batch and re-run `verify-deployment` afterwards.

---

## 4. Upgrades

```bash
UPGRADE_TARGET=depositVault UPGRADE_CONTRACT=DepositVaultV2 \
  pnpm hardhat run scripts/upgrade.ts --network <network> --build-profile production
```

The script validates the new storage layout against the deployed one, deploys the
implementation, and prints the timelock calldata. It never executes the upgrade —
`_authorizeUpgrade` requires `UPGRADER_ROLE`, held only by the timelock.

Rules for writing a new version:

- Keep the `@custom:storage-location erc7201:…` struct and its annotation, even if a field
  becomes unused. Deleting a namespace is a layout break and the validator will reject it.
- Add new state in a **new** namespaced struct, never by appending to an existing one you
  do not own.
- Use `reinitializer(n)` for any migration, and pass the encoded call as the `data`
  argument so the upgrade and the migration are one atomic step.
- Keep `/// @custom:oz-upgrades-unsafe-allow constructor` above the `_disableInitializers()`
  constructor. Without it the validator rejects the contract outright.
- Re-run `verify-deployment` afterwards: an upgrade can change role wiring.

`contracts/mocks/upgrade/BoxBrokenV2.sol` is a deliberately layout-incompatible contract
kept so the rejection path stays tested. Never "fix" it.

---

## 5. Security checklist before going live

- [ ] `pnpm test` green; `pnpm coverage` and `pnpm coverage:branch` at 100% on the core glob.
- [ ] `pnpm lint` clean; Slither reports no high or medium findings.
- [ ] `pnpm size` — every contract under 24,576 bytes on the production profile.
- [ ] `verify-deployment` PASSES before any unpause.
- [ ] Every parameter in `scripts/config.ts` reviewed against §2, not copied from the
      reference values.
- [ ] Operational roles split across distinct keys; nothing collapsed onto one address.
- [ ] Timelock proposer keys stored at multisig-grade custody.
- [ ] Monitoring in place for: `EmergencyAnswerPosted` (every deviation-cap bypass),
      `RefundBlocked` (**the only successful call that moves no money**), `EscrowSwept`,
      `ProviderShortfall` reverts, and every `RoleGranted` on a critical role.
- [ ] An operational commitment that `REQUEST_OPERATOR` rejects stale requests — this is
      what closes the free-option gap and the contracts cannot enforce it.
- [ ] An external audit of the fork. The template being audited does not make your fork
      audited; the parameters and the product subclass are yours.
- [ ] Counsel has reviewed whether `sweepBlockedRefund` is usable in your jurisdiction, and
      whether the client wants `ENFORCER_ROLE` to exist at all.
