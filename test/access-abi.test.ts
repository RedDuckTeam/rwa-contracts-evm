import assert from "node:assert/strict";
import { describe, it } from "node:test";

import hre from "hardhat";

/**
 * Claims about what the contract does *not* expose, which a behavioural test can only
 * approximate: a call to a missing function and a call that reverts look identical.
 */
describe("AccessRegistry ABI surface", () => {
  it("exposes no way to re-point a role's admin", async () => {
    const { abi } = await hre.artifacts.readArtifact("AccessRegistry");
    // Widened to string[] on purpose: Hardhat types the ABI down to a union of the names it
    // contains, so asking whether an absent name is present is a type error rather than a
    // runtime `false` — which makes the negative assertion unexpressible.
    const functionNames: string[] = abi
      .filter((entry) => entry.type === "function")
      .map((entry) => entry.name);

    // A public setter would let a compromised DEFAULT_ADMIN re-point a critical role at
    // itself and grant it immediately, bypassing the timelock.
    assert.ok(
      !functionNames.includes("setRoleAdmin"),
      "AccessRegistry must not expose setRoleAdmin",
    );

    // So a typo in the artifact name could not make the assertion above vacuously true.
    for (const expected of ["grantRole", "revokeRole", "renounceRole", "getRoleAdmin", "isCriticalRole"]) {
      assert.ok(functionNames.includes(expected), `expected ${expected} in the ABI`);
    }
  });

  it("keeps role enumeration available for deployment verification", async () => {
    const { abi } = await hre.artifacts.readArtifact("AccessRegistry");
    // Widened to string[] on purpose: Hardhat types the ABI down to a union of the names it
    // contains, so asking whether an absent name is present is a type error rather than a
    // runtime `false` — which makes the negative assertion unexpressible.
    const functionNames: string[] = abi
      .filter((entry) => entry.type === "function")
      .map((entry) => entry.name);

    // verify-deployment asserts negative facts ("only the RedemptionVault holds
    // REFUND_VAULT_ROLE"), which needs enumeration, not point lookups.
    for (const expected of ["getRoleMember", "getRoleMemberCount", "getRoleMembers"]) {
      assert.ok(functionNames.includes(expected), `expected ${expected} in the ABI`);
    }
  });
});
