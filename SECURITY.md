# Security Policy

A contract or a signing flow ships once and can hold real money — this is the
org-wide default policy for handling that responsibly, and it applies to any
RedDuckTeam repository without its own `SECURITY.md`.

## Reporting a Vulnerability

Please report security issues privately through GitHub Security Advisories on
the specific repository, rather than opening a public issue. If advisories
aren't enabled yet on that repo, contact the maintainers privately before
publishing any details.

Note: enabling private vulnerability reporting is a separate, per-repository
setting (Settings → Security → Private vulnerability reporting) — this file
existing doesn't turn it on by itself.

## Scope

This repository is a permissioned RWA platform, not a trust-minimised one:
privileged roles exist by design, and the issuer is trusted to hold the
underlying assets and compute NAV. Read
[`docs/TRUST-MODEL.md`](docs/TRUST-MODEL.md) first — it inventories every
residual power deliberately left in the system. The most useful report is one
showing the code doing something that document says it cannot.

In scope:

- **Crossing the tier boundary.** Any path that reaches a critical-tier action
  without the 48h timelock, or re-points a role's admin — `AccessRegistry`
  fixes the hierarchy at initialisation and exposes no `setRoleAdmin`.
- **The price path.** Posting a NAV outside the hard bounds, or past the
  deviation cap or cooldown on `setRoundDataSafe`; making a stale answer read
  as healthy.
- **Escrow and the exit paths.** `rejectRequest` and `cancelRequest` must
  require no price and must not be gated by any pause, blacklist, or oracle
  failure. Anything that strands, redirects, or double-spends escrowed funds.
- **The privileged refund.** `refundFromVault` reachable a second time, from
  any path other than the RedemptionVault's single-use ticket, or bypassing
  the sanctions check.
- **Mint/burn separation.** `DepositVault` holding `BURNER_ROLE`,
  `RedemptionVault` holding `MINTER_ROLE`, or any mint not backed by a settled
  deposit.
- **Compliance bypass.** Evading a blacklist, greenlist, or sanctions check —
  including an address lifting its own blacklist status.
- **Upgrades.** Storage-layout collisions, an `initialize` left callable on a
  deployed implementation, or `_authorizeUpgrade` reachable without
  `UPGRADER_ROLE`.
- **Accounting.** Decimals conversion, fee, or rounding logic that resolves in
  the caller's favour against the vault.

Out of scope: the accepted residual risks and the six registered deviations in
`TRUST-MODEL.md` §3–4 — among them the calendar-bucket daily limit, NAV
front-running within the caps, and fail-closed behaviour during an oracle
outage. If one of those looks wrongly sized for a particular deployment, that
is a configuration discussion for [`docs/FORKING.md`](docs/FORKING.md), not a
vulnerability report.

## Important Notes

Most of these repos are actively developed applications, not versioned
libraries — treat `main` as the only supported branch. Templates and demos in
this org are not necessarily audited; check the specific repo's README before
using it with real funds or in production.
