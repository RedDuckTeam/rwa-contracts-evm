import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { upgrades } from "@openzeppelin/hardhat-upgrades/viem";
import hre from "hardhat";

/**
 * `hardhat-upgrades` in viem mode can deploy a UUPS proxy, upgrade it while preserving
 * state, and — the half that protects a live deployment — refuse one that shifts storage.
 */
describe("proxy lifecycle (hardhat-upgrades, viem)", () => {
  it("deploys a UUPS proxy, upgrades it, and preserves state", async () => {
    const connection = await hre.network.create();
    const api = await upgrades(hre, connection);
    const [deployer] = await connection.viem.getWalletClients();
    assert.ok(deployer, "expected a funded wallet client");

    const box = await api.deployProxy("BoxV1", [42n, deployer.account.address], {
      kind: "uups",
    });
    assert.equal(await box.read.value(), 42n);

    const upgraded = await api.upgradeProxy(box.address, "BoxV2", { kind: "uups" });

    // State survives the implementation swap, and the new surface is live.
    assert.equal(await upgraded.read.value(), 42n);
    assert.equal(await upgraded.read.version(), 2n);
  });

  it("rejects an upgrade that shifts existing storage", async () => {
    const connection = await hre.network.create();
    const api = await upgrades(hre, connection);
    const [deployer] = await connection.viem.getWalletClients();
    assert.ok(deployer, "expected a funded wallet client");

    const box = await api.deployProxy("BoxV1", [7n, deployer.account.address], {
      kind: "uups",
    });

    await assert.rejects(
      () => api.upgradeProxy(box.address, "BoxBrokenV2", { kind: "uups" }),
      (error: unknown) => {
        const message = error instanceof Error ? error.message : String(error);
        // Assert on the named layout change, not a generic failure, so a build error cannot
        // masquerade as a passing test.
        assert.match(message, /storage layout|upgrade safety|incompatible/i);
        return true;
      },
    );
  });
});
