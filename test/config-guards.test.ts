import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  PRODUCTION_TIMELOCK_DELAY_SECONDS,
  REFERENCE_CONFIG,
  REPLACE_ME,
  SEPOLIA_CONFIG,
  assertConfigIsDeployable,
  configForNetwork,
  type PlatformConfig,
} from "../scripts/config.js";

/**
 * `assertConfigIsDeployable` runs before the first transaction, so everything it catches is
 * caught for free and everything it misses costs a deployment. These tests exist because a
 * validator that never rejects anything is indistinguishable from no validator at all: each
 * case below constructs the configuration the check exists to refuse and asserts it is
 * refused, and the surrounding cases assert it does not refuse anything else.
 */
describe("deployment configuration guards", () => {
  const sepolia = (overrides: Partial<PlatformConfig> = {}): PlatformConfig => ({
    ...SEPOLIA_CONFIG,
    ...overrides,
    // Pinned rather than inherited, so a test about the timelock cannot pass merely because
    // the placeholder check fired first — nor start failing when a fork fills its own in.
    operationalHolders: {
      pauser: "0x1111111111111111111111111111111111111111",
      requestOperator: "0x2222222222222222222222222222222222222222",
    },
  });

  it("accepts the production reference values", () => {
    assertConfigIsDeployable(REFERENCE_CONFIG, "mainnet");
  });

  /**
   * An operator who edits nothing must get a named error, not a deployment whose PAUSER is an
   * address nobody holds. Asserted against a synthetic config rather than `SEPOLIA_CONFIG`
   * itself: a fork fills that block in on day one, and a test that demanded it stay unfilled
   * would fail for the one repository state that is actually correct.
   */
  it("refuses a config that still holds placeholders, naming every one", () => {
    assert.throws(
      () =>
        assertConfigIsDeployable(
          {
            ...SEPOLIA_CONFIG,
            operationalHolders: { pauser: REPLACE_ME, requestOperator: REPLACE_ME },
          },
          "sepolia",
        ),
      (error: Error) => {
        assert.match(error.message, /REPLACE_ME/);
        // Every offender, so filling one in does not hide the next.
        assert.match(error.message, /operationalHolders\.pauser/);
        assert.match(error.message, /operationalHolders\.requestOperator/);
        return true;
      },
    );
  });

  /**
   * The sentinel is a CONSTANT the check compares against, which makes it possible to "fill in"
   * the config by editing the constant instead of the fields — the deployment then works while
   * the check is disarmed for every field at once. Only its value can catch that, so it is
   * pinned here rather than imported into the assertion.
   */
  it("keeps the placeholder sentinel at a value no deployment would ever use", () => {
    assert.equal(REPLACE_ME, "0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddead");
  });

  /** Whatever this fork has filled in must be deployable, or `pnpm deploy` cannot start. */
  it("accepts this fork's configured Sepolia block", () => {
    assertConfigIsDeployable(SEPOLIA_CONFIG, "sepolia");
  });

  it("names a placeholder wherever it appears, not only in the role holders", () => {
    assert.throws(
      () =>
        assertConfigIsDeployable(
          sepolia({
            paymentTokens: [{ address: REPLACE_ME, feeBps: 0n, allowanceWad: 1n }],
            treasury: REPLACE_ME,
          }),
          "sepolia",
        ),
      (error: Error) => {
        assert.match(error.message, /paymentTokens\[0\]\.address/);
        assert.match(error.message, /treasury/);
        return true;
      },
    );
  });

  it("accepts the Sepolia block once the placeholders are real addresses", () => {
    assertConfigIsDeployable(sepolia(), "sepolia");
  });

  /**
   * The delay IS the reaction window against a compromised admin. Shortening it silently is
   * the shortcut this guard exists to make impossible.
   */
  it("refuses a sub-48h timelock that was not declared", () => {
    const undeclared = sepolia();
    delete undeclared.acceptShortTimelockDelay;
    assert.ok(undeclared.timelockDelaySeconds < PRODUCTION_TIMELOCK_DELAY_SECONDS);

    assert.throws(
      () => assertConfigIsDeployable(undeclared, "sepolia"),
      (error: Error) => {
        assert.match(error.message, /acceptShortTimelockDelay/);
        assert.match(error.message, new RegExp(String(undeclared.timelockDelaySeconds)));
        return true;
      },
    );
  });

  /**
   * The other direction, which is the one that rots: a declaration left behind after the delay
   * was raised would sit in a production config disarming the guard for the next fork.
   */
  it("refuses a declaration left over after the delay was raised", () => {
    assert.throws(
      () =>
        assertConfigIsDeployable(
          sepolia({
            timelockDelaySeconds: PRODUCTION_TIMELOCK_DELAY_SECONDS,
            acceptShortTimelockDelay: true,
          }),
          "sepolia",
        ),
      /Remove the declaration/,
    );
  });

  it("resolves per network, leaving the production values as the default", () => {
    assert.equal(configForNetwork("sepolia"), SEPOLIA_CONFIG);
    assert.equal(configForNetwork("mainnet"), REFERENCE_CONFIG);
    assert.equal(configForNetwork("hardhatMainnet"), REFERENCE_CONFIG);

    // `deploy:local` and CI audit against these; a testnet edit must never reach them.
    assert.equal(REFERENCE_CONFIG.timelockDelaySeconds, PRODUCTION_TIMELOCK_DELAY_SECONDS);
    assert.equal(REFERENCE_CONFIG.acceptShortTimelockDelay, undefined);
  });
});
