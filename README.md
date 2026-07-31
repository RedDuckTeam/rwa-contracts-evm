# Whitelabel fungible RWA platform

A template repository for tokenising fungible real-world assets — bonds, treasury products
and similar NAV-priced instruments. The deliverable is the repository: a client deployment
is a fork of it, with its own parameters and its own thin product contract.

Clean-room implementation on OpenZeppelin 5.6.1, Hardhat 3 and viem, solc 0.8.36.

**Read [`docs/TRUST-MODEL.md`](docs/TRUST-MODEL.md) before deploying anything.** This
platform is not trust-minimised, and that document is where the residual powers are
inventoried and the blast radius of a key compromise is quantified.

## What is here

```
contracts/
  access/       AccessRegistry (DefaultAdminRules + Enumerable), role ids, registry mixin
  compliance/   ComplianceRegistry — blacklist, greenlist, sanctions oracle
  oracle/       AdminNavAggregator (AggregatorV3-compatible) + DataFeed price policy
  pause/        per-operation pause switches
  token/        RwaToken — ERC-20 + 2612 + 165 + 7943
  vaults/       ManageableVault, DepositVault, RedemptionVault
  products/     the per-client contract — a name and a symbol, nothing else
  libraries/    DecimalsConverter
  mocks/        hostile and awkward tokens, a misbehaving sanctions oracle
  testers/      harnesses that make internal branches reachable
scripts/
  config.ts     THE file a fork edits
  deploy.ts     deployment + the Safe grant batch
  handover.ts   stage 2 end to end, for an admin whose key is available locally
  verify-deployment.ts   role and configuration audit
  verify-etherscan.ts    publishes sources for every contract in a deployment
  recover-deployment.ts  rebuilds a lost deployment record from the chain
  accounts.ts   the configured accounts, balances, and what to put in config.ts
  upgrade.ts    storage-layout validation + timelock calldata
docs/
  TRUST-MODEL.md   privileges, blast radius, accepted residual risks, deviations
  FORKING.md       onboarding checklist, sizing rules, the handover runbook
  SEPOLIA.md       the same runbook with testnet values filled in and stage 2 automated
  ACCEPTANCE.md    every acceptance criterion mapped to the test that proves it
```

## Design in one page

**Issuance and redemption are separate contracts.** `DepositVault` holds `MINTER_ROLE` and
never `BURNER_ROLE`; `RedemptionVault` is the mirror. A bug on one side cannot undo the
other, and deployment verification asserts both the positive and the negative.

**One registry holds every privilege**, split into an operational tier the client multisig
controls outright and a critical tier only a `TimelockController` can touch. The role
hierarchy is written once at initialisation and there is no `setRoleAdmin` to re-point it.

**Compliance is one replaceable module.** Blacklist status is a mapping rather than a role,
because `AccessControl` roles are always self-renounceable and a prohibition its subject
can lift is not a prohibition.

**Prices arrive through an adapter.** The vaults depend only on `IDataFeed`, so the bundled
admin-posted aggregator can be swapped for a Chainlink feed without touching a vault. Three
independent constraints bound a compromised NAV key: a per-update deviation cap, a
cooldown, and absolute hard bounds.

**Fail closed on entry, fail open on exit.** Every guardrail blocks new business. None of
them may strand an unresolved request: `rejectRequest` and `cancelRequest` require no price
and are not gated by any pause, and the token exposes a single-use privileged refund path
so a transfer pause or a blacklist cannot trap escrow. Sanctions are the one control that
still applies.

## Getting started

```bash
pnpm install
pnpm build
pnpm test
pnpm deploy:local     # full stack on an in-memory chain, handover included
```

`pnpm deploy:local` deploys everything paused, replays the role-grant batch, waits out the
timelock for the one critical grant, verifies the wiring, posts NAV, unpauses, and runs a
mint → redeem smoke test. That sequence is the production runbook, minus the multisig.

## Commands

| Command | What it does |
| --- | --- |
| `pnpm test` | Solidity and TypeScript suites |
| `pnpm coverage` | line coverage (Hardhat) |
| `FOUNDRY_PROFILE=coverage pnpm coverage:branch` | branch coverage (Foundry — see below) |
| `pnpm lint` / `pnpm slither` | solhint / static analysis |
| `pnpm size` | EIP-170 check on the production profile |
| `pnpm gas` | gas snapshot |
| `pnpm deploy:local` | local bring-up |
| `pnpm accounts --network <n>` | configured accounts and balances |
| `pnpm deploy:sepolia` | deploy to Sepolia — see [`docs/SEPOLIA.md`](docs/SEPOLIA.md) |
| `pnpm handover --network <n>` | complete stage 2 of the handover |
| `pnpm verify-deployment --network <n>` | audit a deployment on a persistent network |
| `pnpm recover-deployment --network <n>` | rebuild a lost `deployments/<n>/` from the chain |
| `pnpm verify:etherscan --network <n>` | publish sources for every deployed contract |

**Foundry is a development-only dependency.** Hardhat 3 reports line and statement coverage
but emits no branch data, and `crytic-compile` cannot read its build-info layout — so
Foundry supplies the branch metric and the frontend Slither compiles through. It is not
part of the production toolchain, and `forge test` is not a gate.

## Forking

Start with [`docs/FORKING.md`](docs/FORKING.md). The short version: edit
`scripts/config.ts`, copy `contracts/products/wbond/` and change the name and symbol, and
leave the core contracts alone. If you find yourself editing `contracts/access`,
`contracts/vaults` or `contracts/token` during onboarding, check the three intended
extension points first.

## Licence

`UNLICENSED` — proprietary, pending a separate business decision.
