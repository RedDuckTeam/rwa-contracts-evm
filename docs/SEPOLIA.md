# Deploying to Sepolia

A rehearsal of the production runbook on a chain where mistakes are free. Read
[`FORKING.md`](FORKING.md) first — this document is that checklist with the testnet-specific
values filled in and the two-stage handover automated.

**What comes out:** nine addresses you can use — seven UUPS proxies, a timelock and a payment
token — plus a completed handover, a passing audit, verified sources on Etherscan and a
mint → redeem smoke test.

**What this is not:** a production deployment. Section 5 lists every way it deliberately
differs, and `verify-deployment` prints them on every run rather than leaving them to be
remembered.

---

## 1. Before you start

| | |
| --- | --- |
| Two Sepolia accounts | The **deployer** pays for the deployment and ends up with no privileges. The **admin** is DEFAULT_ADMIN, timelock proposer and treasury. `deploy.ts` refuses to run if they are the same account. |
| ~0.15 Sepolia ETH on the deployer | Sixteen deployment transactions: seven implementations, seven proxies, the timelock and the mock token. The admin needs a little too — it signs the twenty-odd handover transactions. |
| A Sepolia RPC URL | Any provider. The public endpoints rate-limit hard enough to break a sixteen-transaction run; use a keyed one. |
| An Etherscan API key | [etherscan.io/apidashboard](https://etherscan.io/apidashboard). The v2 API is multichain — one key covers Sepolia. Only needed for `verify:etherscan`. |

Both private keys go into `hardhat.config.ts`'s `accounts` array, in this order:
`[deployer, admin]`. That is the only reason the admin's key is on this machine at all; a
production deployment has a multisig admin and one entry.

## 2. The values you supply

### 2.1 Secrets — four of them

Hardhat 3 resolves `configVariable(...)` from the **environment first, then the encrypted
keystore**. It does *not* read `.env` files. Use the keystore: the values are encrypted at rest
and you are prompted for one password per run.

```bash
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY          # deployer, 0x + 64 hex
npx hardhat keystore set SEPOLIA_ADMIN_PRIVATE_KEY    # admin, a DIFFERENT account
npx hardhat keystore set ETHERSCAN_API_KEY
```

Or export them into the shell, which takes precedence over the keystore:

```bash
export SEPOLIA_RPC_URL=https://... SEPOLIA_PRIVATE_KEY=0x... \
       SEPOLIA_ADMIN_PRIVATE_KEY=0x... ETHERSCAN_API_KEY=...
```

### 2.2 `scripts/config.ts` — two addresses

Everything else in `SEPOLIA_CONFIG` ships with a working value. Exactly two must be replaced,
and the deploy refuses to start until they are:

```ts
operationalHolders: {
  pauser:          "0x…",   // must NOT be the admin
  requestOperator: "0x…",   // must NOT be the admin
},
```

Both may be the **deployer** — a key you already hold, never the admin, and holding
`REQUEST_OPERATOR` is what makes the deposit and redemption *request* flows testable at all.
Print it with:

```bash
pnpm accounts --network sepolia
```

The two constraints are enforced at deploy time, before a transaction is sent:

- `pauser ≠ unpauser` — a key that can both stop and restart the system is not a circuit
  breaker. `unpauser` is unset and falls back to the admin, so `pauser` must not be the admin.
- `requestOperator ≠ vaultAdmin` — the account that moves user funds must not also set the
  limits those movements are checked against. `vaultAdmin` must stay on the admin (see below),
  so `requestOperator` must not be the admin.

`vaultAdmin` is deliberately left on the admin: `grants.json` calls `addPaymentToken`, which is
`onlyRegistryRole(vaultAdminRole())` and executes as the admin. `buildGrantBatch` throws if you
move it while payment tokens are configured, rather than writing a batch that reverts halfway.

The other seven operational roles — `complianceAdmin`, `greenlistOperator`, `blacklistOperator`,
`feedOperator`, `feedAdmin`, `unpauser`, `vaultAdmin` — are unset and fall back to the admin.
On a testnet that is the point: two keys instead of nine. In production, split them
([`FORKING.md`](FORKING.md) §1.3).

### 2.3 Everything else, and what bounds it

Shipped values, the contract constant that caps each, and whether it differs from
`REFERENCE_CONFIG`. A value outside its cap produces a failed deployment, not a live
misconfiguration.

| Field | Sepolia | Rule | vs production |
| --- | --- | --- | --- |
| `timelockDelaySeconds` | `300` (5 min) | `> 0`; below 48 h needs `acceptShortTimelockDelay` | **differs** — 48 h |
| `acceptShortTimelockDelay` | `true` | only valid below 48 h | **testnet only** |
| `oracle.initialAnswer` | `1_00000000` (1.00) | must sit inside the hard bounds | same |
| `oracle.minAnswer` | `50000000` (0.50) | `> 0`, `< maxAnswer` | same |
| `oracle.maxAnswer` | `10_00000000` (10.00) | `> minAnswer` | same |
| `oracle.deviationBps` | `100` (1 %) | `> 0`, ≤ `MAX_DEVIATION_BPS` = 2000 | same |
| `oracle.updateCooldownSeconds` | `300` (5 min) | `> 0`, ≤ `MAX_UPDATE_COOLDOWN` = 7 d | **differs** — 1 h |
| `oracle.healthyDiffSeconds` | `2592000` (30 d) | `> 0`, ≤ `MAX_HEALTHY_DIFF` = 30 d | **differs** — 72 h |
| `oracle.minPriceWad` | `0.5e18` | **must equal** `minAnswer × 1e10` | same |
| `oracle.maxPriceWad` | `10e18` | **must equal** `maxAnswer × 1e10` | same |
| `vault.instantFeeBps` | `100` (1 %) | ≤ `MAX_INSTANT_FEE_BPS` = 500 | same |
| `vault.instantDailyLimitWad` | `1_000_000e18` | `> 0`; UTC calendar bucket — size against 2× | same |
| `vault.minAmountWad` | `10e18` | ≤ `MAX_MIN_AMOUNT_WAD` = 100 000e18 | **differs** — 100e18 |
| `vault.minFirstAmountWad` | `100e18` | ≥ `minAmountWad`, ≤ the same cap | **differs** — 1000e18 |
| `vault.variationToleranceBps` | `100` (1 %) | ≤ `MAX_VARIATION_TOLERANCE_BPS` = 1000 | same |
| `vault.maxSupplyCapWad` | `100_000_000e18` | unbounded; `0` means no cap | same |
| `compliance.sanctionsOracle` | `0x0` | zero disables the gate | same — Chainalysis publishes no Sepolia oracle |
| `compliance.greenlistEnabled` | `false` | — | **differs** — `true` |
| `treasury` | unset ⇒ the admin | a third address needs its key for the handover | same |
| `paymentTokens` | `[]` + the mock | must be non-empty unless a mock is deployed | **testnet only** |

The two `minPriceWad`/`maxPriceWad` values describe the same band as the aggregator's bounds,
in WAD rather than feed decimals. `verify-deployment` compares them on-chain: a mismatch means
the aggregator accepts prices the DataFeed then refuses, which looks healthy to the operator and
is dead to the vaults.

**The payment token.** `DEPLOY_MOCK_PAYMENT_TOKEN=1` deploys a 6-decimal `MockERC20` and
registers it, which is what makes the testnet usable — anyone can mint it, so the treasury float
and the smoke test cost nothing. To use a real Sepolia ERC-20 instead, drop the flag and list it
in `paymentTokens`; Circle's test USDC is
`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (6 decimals). More than 18 decimals is rejected
outright.

## 3. Deploy

```bash
pnpm install
DEPLOY_MOCK_PAYMENT_TOKEN=1 pnpm deploy:sepolia
pnpm handover --network sepolia
pnpm verify:etherscan --network sepolia
```

`deploy:sepolia` and `handover` both pin `--build-profile production`. That is not optional:
the profile is part of the deployed bytecode, and verification compares against a local compile.

**`pnpm deploy:sepolia`** deploys everything **paused** with the greenlist enforced, takes the
admin from the second configured account, and writes four files under `deployments/sepolia/`:

- `addresses.json` — the address book
- `deployment.json` — addresses, role holders and the configuration actually used. Every later
  step reads this rather than re-importing `config.ts`, so the audit checks the chain against
  what was deployed and not against the defaults it started from.
- `grants.json` — a Safe Transaction Builder batch. Every entry takes effect immediately except
  the last, which only *schedules* the critical `REFUND_VAULT` grant.
- `treasury-actions.json` — the provider approvals. These must be signed **by the treasury**: an
  `approve` is authorised by `msg.sender`.

It also writes `.openzeppelin/sepolia.json`, the proxy manifest. **Commit it.** It records the
storage layout of every implementation and is what lets `scripts/upgrade.ts` prove a future
upgrade is safe.

**`pnpm handover`** is [`FORKING.md`](FORKING.md) §3 stage 2 end to end: it replays both
batches, waits out the timelock, executes the scheduled grant, runs the audit, funds the
treasury float, posts NAV, unpauses in the correct order, re-audits and runs a mint → redeem
smoke test. Every step is resumable — re-run it after an interruption and it picks up from
whatever already landed. It needs the admin's key; with a multisig admin, execute `grants.json`
through the Safe UI first and then run it for the rest.

Useful variables: `SKIP_SMOKE_TEST=1`, `HANDOVER_FLOAT=<whole units>` (default `10000000`).

## 4. Afterwards

```bash
pnpm verify-deployment --network sepolia               # audit, expecting the paused posture
EXPECT_LIVE=1 pnpm verify-deployment --network sepolia # audit a running deployment
pnpm recover-deployment --network sepolia              # rebuild deployments/sepolia/ from chain
```

`deployments/` is keyed by network **name**, not by chain, so a second configuration reusing a
name overwrites the first one's record. Every record now carries its `chainId` and every reader
refuses a mismatch, but the overwrite itself is not prevented — `recover-deployment` rebuilds
the record from the chain plus `.openzeppelin/sepolia.json`. That manifest is the one thing that
cannot be rebuilt: it holds storage layouts that exist nowhere on chain. Commit it.

No wallet needs admitting — the greenlist is off, so any address that is not blacklisted can
deposit. To bar one: `setBlacklisted(account, true)` as `BLACKLIST_OPERATOR` (the admin).

To move NAV: `setRoundDataSafe(answer)` as `FEED_OPERATOR` (the admin), no more than
`deviationBps` from the last answer and no sooner than `updateCooldownSeconds` after it. With
a 30-day window you do not have to; to change that window, `setHealthyDiff(seconds)` on the
`DataFeed` as `FEED_ADMIN` (the admin) — no timelock proposal, capped at 30 days.

## 5. How this differs from production

Six deviations, all in `SEPOLIA_CONFIG` and all marked there:

1. **A 5-minute timelock instead of 48 h.** This is the whole reason the bring-up finishes in
   one sitting. It is also the reaction window against a compromised admin, so
   `verify-deployment` reports it as a **WAIVED** check on every run — a failure that was
   declared, never a pass. Removing `acceptShortTimelockDelay` from the config makes the same
   deployment fail its audit.
2. **A mock payment token**, mintable by anyone.
3. **Two keys instead of nine.** Seven operational roles sit on the admin.
4. **Lower minimum deposit amounts**, so a first deposit does not need four figures.
5. **Blacklist only — the greenlist is off.** No wallet needs admitting before it can deposit.
   The blacklist and the sanctions gate are unaffected: both run on every transfer and every
   vault operation regardless. `setGreenlistEnabled(true)` as `COMPLIANCE_ADMIN` turns the
   allowlist back on at runtime, with no redeploy and no timelock.
6. **A 30-day staleness window instead of 72 h**, so nobody has to post NAV to keep a testnet
   alive. In production this is how long a stale price stays tradeable and belongs just above
   your real posting interval.

The contracts themselves are the production ones, compiled on the production profile, with one
consequence worth naming: `AccessRegistry.initialize` takes the admin-transfer delay as a
parameter rather than reading a constant, so a testnet can pass a short one. The registry's
delay and the timelock's `minDelay` come from the same config value and `verify-deployment`
asserts they are equal on-chain — if they diverged, the shorter one would set the real reaction
window while the longer one made the deployment look safer than it is.
