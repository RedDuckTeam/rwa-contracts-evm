# Trust model

This platform is **not** trust-minimised, and pretending otherwise would be the most
dangerous thing this document could do. It is a permissioned RWA product: an issuer holds
the underlying assets, computes NAV off-chain, and decides who may subscribe. The on-chain
contracts cannot make that trust unnecessary. What they can do — and what this document
accounts for — is bound how much damage a compromised or dishonest operator can do before
anyone reacts.

Read this before deploying a fork. `docs/FORKING.md` turns its conclusions into concrete
configuration rules.

---

## 1. The aggregate risk statement

Two observations matter more than any list of individual failure modes.

### 1.1 Stress is correlated with the guardrails firing

The circuit breakers that stop the system — a NAV move beyond the hard bounds, a stale
feed, a sanctions oracle that stops answering — do not fire at random moments. They fire
during exactly the events that make people want to exit: a repricing, an infrastructure
outage, a market dislocation.

So a guardrail sized to be "tight and safe" in calm conditions becomes a guardrail that
locks the doors during a fire. The hard bounds on the aggregator are the sharpest example:
a NAV move outside them cannot be posted at all until the bounds are widened through the
timelock, which is roughly **48 hours of fail-closed operation**. That is a deliberate
trade, and it is only defensible if the bounds are set as a **last-resort breaker with
real headroom**, not as a working corridor.

**Mitigating structural property, which must be said out loud:** every fail-closed window
in this system blocks only **price-dependent** actions — instant deposits, instant
redemptions, and request approval. The **exit paths do not require a price**:

| Action | Needs a healthy price? | Blocked by an operation pause? |
| --- | --- | --- |
| `depositInstant` / `redeemInstant` | yes | yes |
| `approve*Request` | yes | yes |
| **`rejectRequest`** | **no** | **no** |
| **`cancelRequest`** | **no** | **no** |

A user with a pending request is therefore never locked in by an oracle failure, a price
excursion, or a pause. They can always walk away with exactly what they escrowed. The
mirror of that — the "free option" a cancellable, never-expiring request would otherwise
hand the user — is closed by `REQUEST_OPERATOR`'s standing obligation to reject stale
requests, which also works during an incident precisely because rejection needs no price.

### 1.2 The dominant risk is key compromise, not component failure

Ranking the individual component failures below misses the real shape of the risk. The
largest single contributor to the aggregate profile is **compromise of the operational
multisig**, for a structural reason: the fast defences are self-reversible by whoever holds
the key, and the countermeasures are all behind the 48-hour timelock.

An attacker holding `DEFAULT_ADMIN_ROLE` can, immediately:

- unpause anything (`UNPAUSER_ROLE`), and revoke `PAUSER_ROLE` from the monitoring bot;
- greenlist themselves;
- move NAV to the edge of the hard bounds through `FEED_ADMIN_ROLE`, bypassing the
  deviation cap;
- extend the staleness window to 30 days (`FEED_ADMIN_ROLE` again — see §2.2), keeping a
  price they posted tradeable for that long;
- drain value through instant operations, up to the daily limit.

They **cannot**, without waiting out the timelock:

- upgrade any contract (`UPGRADER_ROLE` → timelock only);
- swap the `ComplianceRegistry` or the price feed (`CRITICAL_CONFIG_ROLE` → timelock only);
- change `tokensReceiver`, `feeReceiver`, `tokensProvider` or `blockedFundsReceiver`;
- widen the hard bounds, the deviation cap, the cooldown, or `variationTolerance`;
- confiscate anything (`ENFORCER_ROLE` is granted to **nobody** at deployment);
- grant themselves `REFUND_VAULT_ROLE`.

#### Blast radius

The value an attacker can extract before a 48-hour countermeasure lands is bounded by:

```
radius  ≈  instantDailyLimitWad  ×  days_until_response  ×  (bound_width − 1)
```

where `bound_width = maxAnswer / trueNAV` — how far above the true NAV they can push the
posted price before the hard bounds stop them.

With the reference configuration (`instantDailyLimit = 1,000,000 wBOND`,
`maxAnswer = 10.00` against a true NAV of `1.00`, so `bound_width = 10`) and a two-day
response:

```
1,000,000 × 2 × (10 − 1)  =  18,000,000 units of over-payment at risk
```

That number is uncomfortably large, and it is meant to be: it is what a fork gets by
copying the reference bounds without thinking. The two levers are visible directly in the
formula.

- **Narrowing the hard bounds is by far the strongest lever.** Bounds of `0.80 / 1.25`
  against a NAV of `1.00` reduce the same figure to `1,000,000 × 2 × 0.25 = 500,000` — a
  36× reduction — at the cost of a fail-closed window if NAV ever legitimately moves more
  than 25%.
- **The daily limit scales it linearly**, and it is the lever to reach for when NAV is
  genuinely volatile and the bounds must stay wide.

`docs/FORKING.md` states the resulting sizing rule. Note that the fastest available
response is not a countermeasure at all but a **pause of `OP_ORACLE_UPDATE`**, which any
`PAUSER_ROLE` holder can apply instantly and which stops both NAV posting paths — including
the emergency one. Every `FEED_ADMIN` post emits a dedicated `EmergencyAnswerPosted` event
for exactly this reason: it is the signal monitoring should page on.

---

## 2. Privilege inventory

### 2.1 Two tiers, and why the delays are equal

| Tier | Who | Delay |
| --- | --- | --- |
| Operational | client multisig (`DEFAULT_ADMIN`) and the roles it grants | none |
| Critical | `TimelockController` only | `minDelay`, 48h by default |

Transferring `DEFAULT_ADMIN_ROLE` itself is also delayed 48h, by
`AccessControlDefaultAdminRules`. **The two delays are deliberately equal.** If the admin
rotation were slower than the timelock, an attacker who compromised the multisig could push
a critical change through before a legitimate rotation completed. Equal delays mean the
rotation always finishes first or simultaneously.

The hierarchy is fixed once, in `AccessRegistry.initialize`. There is **no public
`setRoleAdmin`** — asserted by both a raw-call test and an ABI-shape test — because a
compromised admin who could re-point a critical role's admin at itself would route around
the timelock entirely.

Critical roles are also **non-renounceable**. Renouncing is the one move a role holder can
make with nobody's approval, and for the timelock it would be terminal: dropping
`TIMELOCK_ADMIN_ROLE` leaves nobody able to grant critical roles ever again, permanently
bricking upgrades.

### 2.2 Role map

| Role | Default holder | Administered by | Can do |
| --- | --- | --- | --- |
| `DEFAULT_ADMIN` | client multisig | itself (2-step, 48h) | grant/revoke operational roles |
| `TIMELOCK_ADMIN` | timelock only | `TIMELOCK_ADMIN` | administer critical roles |
| `UPGRADER` | timelock only | `TIMELOCK_ADMIN` | authorise UUPS upgrades |
| `CRITICAL_CONFIG` | timelock only | `TIMELOCK_ADMIN` | feed/compliance pointers, treasury addresses, oracle bounds, deviation, cooldown, variation tolerance, sweeps |
| `REFUND_VAULT` | RedemptionVault only | `TIMELOCK_ADMIN` | call `refundFromVault` on the token |
| `ENFORCER` | **nobody** | `TIMELOCK_ADMIN` | `forcedTransfer`, `setFrozenTokens` |
| `COMPLIANCE_ADMIN` | multisig | `DEFAULT_ADMIN` | toggle `greenlistEnabled` |
| `GREENLIST_OPERATOR` / `BLACKLIST_OPERATOR` | ops | `DEFAULT_ADMIN` | maintain the lists |
| `REQUEST_OPERATOR` | ops | `DEFAULT_ADMIN` | approve/reject requests |
| `VAULT_ADMIN` | multisig | `DEFAULT_ADMIN` | fees, limits, minimums, waivers, token registry — all inside coded caps |
| `FEED_OPERATOR` | NAV bot | `DEFAULT_ADMIN` | `setRoundDataSafe` (deviation + cooldown apply) |
| `FEED_ADMIN` | multisig | `DEFAULT_ADMIN` | `setRoundData` — emergency post, bypasses deviation and cooldown, never the hard bounds; `DataFeed.setHealthyDiff` — the staleness window, capped at `MAX_HEALTHY_DIFF` = 30 days |
| `PAUSER` | monitoring bot | `DEFAULT_ADMIN` | pause only |
| `UNPAUSER` | multisig | `DEFAULT_ADMIN` | unpause only |
| `MINTER` / `BURNER` | DepositVault / RedemptionVault | `DEFAULT_ADMIN` | mint / burn |

`PAUSER` and `UNPAUSER` are split so the hot monitoring key can only ever make the system
safer. A single role holding both would make the circuit breaker self-resettable by
whoever compromised it.

**`setHealthyDiff` sits with `FEED_ADMIN`, not the timelock**, and is the one feed-policy
knob that does. The reasoning is that the same role already decides the *answer*:
`setRoundData` posts any value inside the hard bounds immediately, bypassing both the
deviation cap and the cooldown. A compromised `FEED_ADMIN` wanting the vaults to trade on a
price of its choosing posts one — it does not need an old price to keep being accepted. So
timelocking the staleness window bought little, while making the single parameter that must
track the real NAV posting cadence cost a full delay to correct — and a `healthyDiff` set
below the posting interval takes the product down during entirely normal operation.

What it does buy the attacker is *duration*: a price they posted stays tradeable for up to
`MAX_HEALTHY_DIFF` = 30 days rather than 72 hours. The compensating control is unchanged and
is not this parameter — pausing `OP_ORACLE_UPDATE` stops both posting paths instantly, and
pausing the vault operations stops trading on a price already posted. Everything that
*bounds* the damage rather than timing it stays behind the timelock: the hard bounds, the
price bounds, the deviation cap, the cooldown and the aggregator pointer.

### 2.3 The one documented exception to "one registry holds all privileges"

`TimelockController` carries its own internal `AccessControl` (`PROPOSER`, `EXECUTOR`,
`CANCELLER`). This is not resolved through the `AccessRegistry` and cannot be. It is an
isolated domain belonging to the delay mechanism itself, deployed with:

```
minDelay  = 48h
proposers = [client multisig]      (automatically also CANCELLER)
executors = [address(0)]           (open executor — anyone may execute a matured proposal)
admin     = address(0)             (the role set is final at construction)
```

The open executor is intentional: it means a matured, publicly visible proposal cannot be
withheld by whoever proposed it.

---

## 3. Accepted residual risks

Each of these is a known, deliberate trade. None is a defect.

**Concentration in the `ComplianceRegistry`.** One contract answers every compliance
question for the whole deployment. If it is misconfigured, everything is misconfigured.
The mitigation is that it is *replaceable* through the timelock rather than embedded, so a
fork can swap the rulebook without touching or re-auditing the core.

**`refundFromVault` bypasses the transfer pause and the blacklist.** Constrained to a
single-use transient ticket keyed by the exact `(from, to, amount)` triple, callable only
by `REFUND_VAULT_ROLE` — a critical, timelock-granted role held solely by the
RedemptionVault. It is unreachable from any other path and unreachable a second time inside
the same transaction. It does **not** bypass sanctions.

**Blacklisted users can still be refunded.** This is a deliberate refusal to confiscate on
the exit path. A blacklist stops someone transacting; it is not a court order transferring
their property. Sanctions are treated differently, and are the one control the carve-out
does not relax.

**`sweepBlockedRefund` is a confiscation primitive.** Whether it is lawful to use is a
question for the client's counsel, not for this repository. On-chain, `Swept` is terminal
and irreversible; restitution is an off-chain matter. Two properties limit it: it requires
a full timelock delay, and it **retries the refund at execution time**, so an owner whose
block was lifted during the delay is paid rather than swept.

**A payment token's own blacklist can block a refund.** USDC and USDT run blacklists
entirely outside this system. When one refuses a refund, the cancellation completes without
moving money, emits `RefundBlocked`, and leaves the request `Pending` and sweep-eligible.
The user can simply cancel again once unblocked. **`RefundBlocked` is the only event in the
system that signals a successful call that moved no money — monitor it as an alert.**

**NAV-token escrow is out of reach of `setFrozenTokens`.** Tokens inside a redemption
request belong to the vault, not the user, so freezing the user's balance does not reach
them. An enforcer racing a user who front-runs a freeze by submitting a request will lose
that race; the mitigation is `rejectRequest`, which returns the escrow so the freeze can
then apply.

**A true NAV outside the hard bounds means ~48h of fail-closed operation.** See §1.1.
Exits remain open throughout.

**Sanctions-oracle failure stops money paths until a timelocked replacement lands.**
Serving a sanctioned party is judged worse than an outage. The oracle is called with a
100,000-gas cap so it cannot burn the caller's budget, and any anomaly — revert,
out-of-gas, wrong-length return data, an address with no code — counts as "cannot vouch".
The ERC-7943 view predicates return `false` rather than reverting, as the standard requires.

**The daily limit is a UTC calendar bucket, not a rolling window.** Spending the full limit
late on one day and again early on the next puts **up to 2× the limit** through a single
rolling 24-hour window. Registered as deviation #3, asserted by
`test_CalendarBucketAllowsUpTo2xInARolling24hWindow`, and turned into a sizing rule in
`FORKING.md`.

**NAV front-running.** A user who sees a NAV update coming can transact just before it.
Bounded by the deviation cap (1% per update), the cooldown (1h, and a cooldown of zero is
refused outright), and the daily limit.

**A refund attempt must be adequately funded.** `rejectRequest` and `cancelRequest` check a
`MIN_REFUND_GAS` floor before attempting the transfer. Without it, EIP-150's 63/64 rule
would let a caller supplying a tight gas limit make the inner transfer die while the outer
frame survived to record "the token refused" — letting a compromised `REQUEST_OPERATOR`
mark every pending request sweep-eligible with no token having refused anything.

**`AdminNavAggregator.getRoundData` does not serve history.** It returns the CURRENT
answer for any round id. The vaults read only `latestRoundData`, so nothing here is
affected, but a third-party integrator treating it as a genuine `AggregatorV3Interface`
history source would be misled. Documented in the contract's NatSpec; a fork exposing the
aggregator to external consumers should either implement real round storage or say so.

**Operator obligation.** `REQUEST_OPERATOR` must actively reject stale requests. This is an
operational commitment the contracts cannot enforce; see §1.1 for why it is what closes the
free-option gap.

---

## 4. Registered deviations from the specification

Six, all deliberate and all covered by tests.

1. **Branch coverage is measured by Foundry, not Hardhat.** Hardhat 3 / EDR reports line
   and statement coverage but emits no branch data. Foundry is a development-only
   dependency used solely for this metric.
2. **Under an `OP_TRANSFER` pause, `canSend` reports `false` while `refundFromVault` still
   succeeds.** The ERC-7943 predicates describe the ordinary transfer path; the privileged
   refund is by construction not that path. Recorded in the token's NatSpec and asserted by
   `test_CanSendReportsFalseWhileRefundsStillSucceed`.
3. **The daily limit is a calendar bucket rather than a rolling window**, admitting up to
   2× in a rolling 24h window. See §3.
4. **Per-product role namespacing was removed.** The axis of this template is "one fork,
   one deployment", so namespacing was an artefact of a different architecture. The virtual
   role getters remain, and a multi-product fork **must** override the vault-bound ones —
   `MINTER`, `BURNER`, `REFUND_VAULT`.
5. **A fifth terminal request status, `Swept`, was added.** The original state list had
   four; the emergency sweep needs a distinct terminal state so a swept request can never
   be confused with an ordinary cancellation.
6. **`DataFeed.setHealthyDiff` is held by `FEED_ADMIN` rather than `CRITICAL_CONFIG`.**
   Reasoning in §2.2. Asserted by `test_FeedAdminAdjustsTheStalenessWindow` and by
   `test_RevertWhen_StalenessWindowIsChangedByTheTimelock`, which exists so the change reads
   as "moved" and not "reachable by both".
