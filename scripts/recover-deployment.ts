/**
 * Rebuilds `deployments/<network>/` from the chain when the record has been lost.
 *
 *   pnpm recover-deployment --network sepolia
 *
 * The record is not the source of truth — the chain is — but every later step reads the record:
 * `verify-deployment` audits against it, `handover` resumes from it, `verify:etherscan`
 * enumerates from it. Losing it strands a perfectly healthy deployment.
 *
 * The one thing that CANNOT be rebuilt is `.openzeppelin/<network>.json`, the proxy manifest:
 * it records storage layouts that exist nowhere on chain, and this script needs it to know
 * which addresses belong to the deployment at all. Commit it. If it is gone too, the addresses
 * have to come from the deploy transcript or a block explorer and be passed to
 * `hardhat-upgrades`' `forceImport`.
 *
 * Every value is READ from the chain rather than taken from `scripts/config.ts`, so the result
 * describes the deployment that exists — including any parameter changed since. A recovered
 * record that echoed the config file would make the audit compare the chain against an
 * assumption instead of against what was deployed.
 *
 * There is exactly one exception, and it is announced when it happens: an operational role held
 * by NOBODY has nothing to read, which means the grant batch never ran. Those come from
 * `scripts/config.ts`, because a record that named the zero address would regenerate a
 * `grants.json` granting roles to nobody.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import hre from "hardhat";
import { getAddress, type Address } from "viem";

import {
  ROLE_IDS,
  assertRoleSeparation,
  buildGrantBatch,
  resolveOperationalHolders,
  writeAddressBook,
  writeDeploymentRecord,
  writeGrantBatch,
  type AddressBook,
  type OperationalHolders,
} from "./lib/deployment.js";
import {
  PRODUCTION_TIMELOCK_DELAY_SECONDS,
  configForNetwork,
  type PlatformConfig,
} from "./config.js";

const log = (message: string) => console.log(message);
const ZERO = "0x0000000000000000000000000000000000000000" as const;

const connection = await hre.network.getOrCreate();
const publicClient = await connection.viem.getPublicClient();

const EPHEMERAL = /^(default|hardhat.*)$/;
if (EPHEMERAL.test(connection.networkName)) {
  log(`Network "${connection.networkName}" is an in-memory development chain — nothing to recover.`);
  process.exit(1);
}

const manifestPath = join(process.cwd(), ".openzeppelin", `${connection.networkName}.json`);
if (!existsSync(manifestPath)) {
  log(`No ${manifestPath}.`);
  log("Without the proxy manifest there is no record of which addresses belong to this");
  log("deployment. Recover the addresses from the deploy transcript or a block explorer and");
  log("re-import them with hardhat-upgrades' forceImport before running this.");
  process.exit(1);
}

const proxies: Address[] = (
  JSON.parse(readFileSync(manifestPath, "utf8")) as { proxies?: { address: Address }[] }
).proxies?.map((p) => getAddress(p.address)) ?? [];

if (proxies.length === 0) {
  log(`${manifestPath} lists no proxies.`);
  process.exit(1);
}

log(`network:  ${connection.networkName} (chain ${await publicClient.getChainId()})`);
log(`manifest: ${proxies.length} proxies`);
log("");

/* ------------------------------------------------------------------------ */
/*            Identify each proxy by what it answers, not by order          */
/* ------------------------------------------------------------------------ */

/**
 * The manifest lists proxies in deployment order, which is deterministic — and relying on that
 * would silently mis-map every address the day the deployment graph gains a contract. Each
 * proxy is instead asked a question only it can answer.
 */
const PROBES = [
  ["AccessRegistry", "defaultAdmin"],
  ["ComplianceRegistry", "greenlistEnabled"],
  ["AdminNavAggregator", "hardBounds"],
  ["DataFeed", "priceBounds"],
  ["WbondToken", "symbol"],
  ["DepositVault", "maxSupplyCapWad"],
  ["RedemptionVault", "tokensProvider"],
] as const;

const found = new Map<string, Address>();

for (const address of proxies) {
  for (const [name, probe] of PROBES) {
    if (found.has(name)) continue;
    try {
      const contract = await connection.viem.getContractAt(name, address, {
        client: { public: publicClient },
      });
      const read = contract.read as unknown as Record<string, () => Promise<unknown>>;
      const call = read[probe];
      if (call === undefined) continue;
      await call();
      found.set(name, address);
      log(`  ${name.padEnd(19)} ${address}`);
      break;
    } catch {
      // Not this contract — every other proxy rejects the probe, which is the point.
    }
  }
}

const missing = PROBES.map(([name]) => name).filter((name) => !found.has(name));
if (missing.length > 0) {
  log("");
  log(`Could not identify: ${missing.join(", ")}.`);
  log("The manifest does not describe a complete deployment of this platform.");
  process.exit(1);
}

const need = (name: string): Address => {
  const address = found.get(name);
  if (address === undefined) throw new Error(`unreachable: ${name} was verified present`);
  return address;
};

/* ------------------------------------------------------------------------ */
/*                   Everything else, read off the chain                    */
/* ------------------------------------------------------------------------ */

const at = async <N extends string>(name: N, address: Address) =>
  connection.viem.getContractAt(name, address, { client: { public: publicClient } });

const accessRegistry = await at("AccessRegistry", need("AccessRegistry"));
const compliance = await at("ComplianceRegistry", need("ComplianceRegistry"));
const aggregator = await at("AdminNavAggregator", need("AdminNavAggregator"));
const dataFeed = await at("DataFeed", need("DataFeed"));
const depositVault = await at("DepositVault", need("DepositVault"));
const redemptionVault = await at("RedemptionVault", need("RedemptionVault"));

// The timelock is not a proxy and so is not in the manifest. It is the sole holder of
// TIMELOCK_ADMIN_ROLE by construction, which the registry can enumerate.
const timelockMembers = await accessRegistry.read.getRoleMembers([ROLE_IDS.TIMELOCK_ADMIN]);
const timelock = timelockMembers[0];
if (timelockMembers.length !== 1 || timelock === undefined) {
  log("");
  log(`TIMELOCK_ADMIN_ROLE is held by ${timelockMembers.length} accounts, expected exactly 1.`);
  log("The timelock address cannot be determined; this deployment needs manual inspection.");
  process.exit(1);
}

const admin = getAddress(await accessRegistry.read.defaultAdmin());

/**
 * The one place the chain is not the whole answer. A role with exactly one holder is the shape
 * a completed handover leaves, and that holder is recorded. A role with NO holder means the
 * grant batch has not been executed — there is nothing on chain to read, and recording the zero
 * address would produce a `grants.json` that grants roles to nobody. The INTENDED holder is
 * what the record needs there, and it comes from `scripts/config.ts`, which is what the deploy
 * used. Both cases are named in the output so the record is never mistaken for pure observation.
 */
const intended = resolveOperationalHolders(admin, configForNetwork(connection.networkName));
const fromConfig: string[] = [];

const holderFor = async (
  label: string,
  role: `0x${string}`,
  key: keyof OperationalHolders,
): Promise<Address> => {
  const members = await accessRegistry.read.getRoleMembers([role]);

  if (members.length === 1 && members[0] !== undefined) return getAddress(members[0]);

  if (members.length === 0) {
    fromConfig.push(label);
    return getAddress(intended[key]);
  }

  log(`  WARNING: ${label} is held by ${members.length} accounts: ${members.join(", ")}`);
  log(`           Recording the configured holder (${intended[key]}). verify-deployment will`);
  log("           report the extras as a failure, which is correct — an unexpected holder of");
  log("           an operational role is exactly what the audit exists to surface.");
  return getAddress(intended[key]);
};

const holders: OperationalHolders = {
  complianceAdmin: await holderFor("COMPLIANCE_ADMIN", ROLE_IDS.COMPLIANCE_ADMIN, "complianceAdmin"),
  greenlistOperator: await holderFor("GREENLIST_OPERATOR", ROLE_IDS.GREENLIST_OPERATOR, "greenlistOperator"),
  blacklistOperator: await holderFor("BLACKLIST_OPERATOR", ROLE_IDS.BLACKLIST_OPERATOR, "blacklistOperator"),
  requestOperator: await holderFor("REQUEST_OPERATOR", ROLE_IDS.REQUEST_OPERATOR, "requestOperator"),
  vaultAdmin: await holderFor("VAULT_ADMIN", ROLE_IDS.VAULT_ADMIN, "vaultAdmin"),
  feedOperator: await holderFor("FEED_OPERATOR", ROLE_IDS.FEED_OPERATOR, "feedOperator"),
  feedAdmin: await holderFor("FEED_ADMIN", ROLE_IDS.FEED_ADMIN, "feedAdmin"),
  pauser: await holderFor("PAUSER", ROLE_IDS.PAUSER, "pauser"),
  unpauser: await holderFor("UNPAUSER", ROLE_IDS.UNPAUSER, "unpauser"),
};

if (fromConfig.length > 0) {
  log("");
  log(`  ${fromConfig.length} role(s) are held by nobody on chain, so the handover has not run.`);
  log(`  Taken from scripts/config.ts instead: ${fromConfig.join(", ")}.`);
  log("  Check they are what you intend before running the handover — they are the only");
  log("  values here that the chain did not confirm.");
}

// A collapsed pair would produce a batch that cannot pass its own audit, which is the check
// `deploy.ts` runs before writing one. Recovery must not quietly hand back a worse record.
assertRoleSeparation(holders);

const treasury = getAddress(await redemptionVault.read.tokensProvider());
const registered = await depositVault.read.paymentTokens();

const addresses: AddressBook = {
  network: connection.networkName,
  admin,
  timelock: getAddress(timelock),
  accessRegistry: need("AccessRegistry"),
  complianceRegistry: need("ComplianceRegistry"),
  aggregator: need("AdminNavAggregator"),
  dataFeed: need("DataFeed"),
  token: need("WbondToken"),
  depositVault: need("DepositVault"),
  redemptionVault: need("RedemptionVault"),
  // Filled in below: this slot means "the mock a testnet bring-up deployed", not "a registered
  // payment token". Every registered token is in the config.
  paymentToken: ZERO,
  treasury,
};

/**
 * `addresses.paymentToken` drives two things that must never touch a real asset: `handover.ts`
 * mints the treasury float through it, and `verify:etherscan` publishes it as `MockERC20`. The
 * deploy script sets it only when it deployed the stand-in, and nothing on chain says which
 * token that was — so the token is asked instead. `MockERC20.mint` is unrestricted; every real
 * stablecoin's is not, so a simulated zero-value mint from an arbitrary account succeeds on
 * exactly one of them.
 */
const MINT_ABI = [
  {
    type: "function",
    name: "mint",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

for (const token of registered) {
  try {
    await publicClient.simulateContract({
      address: getAddress(token),
      abi: MINT_ABI,
      functionName: "mint",
      args: [admin, 0n],
      account: admin,
    });
  } catch {
    continue; // Restricted or absent: somebody else's contract, and not ours to mint.
  }
  addresses.paymentToken = getAddress(token);
  log("");
  log(`  ${token} mints on demand — recorded as the deployment's mock payment token.`);
  break;
}

const timelockContract = await at("RwaTimelockController", addresses.timelock);
const minDelay = await timelockContract.read.getMinDelay();
const [minAnswer, maxAnswer] = await aggregator.read.hardBounds();
const [minPriceWad, maxPriceWad] = await dataFeed.read.priceBounds();
const [, currentAnswer] = await aggregator.read.latestRoundData();

const paymentTokens: PlatformConfig["paymentTokens"] = [];
for (const token of registered) {
  const tokenConfig = await depositVault.read.paymentTokenConfig([token]);
  paymentTokens.push({
    address: getAddress(token),
    feeBps: tokenConfig.feeBps,
    allowanceWad: tokenConfig.remainingAllowanceWad,
  });
}

const config: PlatformConfig = {
  timelockDelaySeconds: minDelay,
  // Recorded because the audit's 48h floor check reads it. Derived from the delay actually
  // deployed, so a recovered testnet keeps reporting the deviation it was launched with.
  ...(minDelay < PRODUCTION_TIMELOCK_DELAY_SECONDS ? { acceptShortTimelockDelay: true } : {}),
  oracle: {
    // The answer standing NOW, not the one written at initialisation — that value is not
    // retained on chain, and this is the one every later step would post anyway.
    initialAnswer: currentAnswer,
    minAnswer,
    maxAnswer,
    deviationBps: await aggregator.read.deviationBps(),
    updateCooldownSeconds: await aggregator.read.updateCooldown(),
    healthyDiffSeconds: await dataFeed.read.healthyDiff(),
    minPriceWad,
    maxPriceWad,
  },
  vault: {
    instantFeeBps: await depositVault.read.instantFeeBps(),
    instantDailyLimitWad: await depositVault.read.instantDailyLimitWad(),
    minAmountWad: await depositVault.read.minAmountWad(),
    minFirstAmountWad: await depositVault.read.minFirstAmountWad(),
    variationToleranceBps: await depositVault.read.variationToleranceBps(),
    maxSupplyCapWad: await depositVault.read.maxSupplyCapWad(),
  },
  compliance: {
    sanctionsOracle: getAddress(await compliance.read.sanctionsOracle()),
    greenlistEnabled: await compliance.read.greenlistEnabled(),
  },
  treasury,
  paymentTokens,
  // The observed assignment, so the record is self-consistent: re-deploying from it would
  // reproduce the wiring that exists rather than fall back to putting every role on the admin.
  operationalHolders: holders,
};

/* ------------------------------------------------------------------------ */

const chainId = await publicClient.getChainId();

log("");
log(`addresses: ${writeAddressBook(addresses)}`);
log(`record:    ${writeDeploymentRecord({ addresses, holders, config, chainId })}`);

// Regenerated so a resumed handover has something to replay. Every entry is already executed
// on a completed deployment; `handover.ts` simulates each one first and skips what reverts.
const batch = buildGrantBatch(addresses, holders, config);
log(`grants:    ${writeGrantBatch(addresses, chainId, batch.multisig)}`);
if (batch.treasury.length > 0) {
  log(
    `treasury:  ${writeGrantBatch(addresses, chainId, batch.treasury, "treasury-actions.json", {
      name: "RWA platform — treasury actions",
      description:
        `Execute as the tokensProvider (${addresses.treasury}), NOT as the admin multisig. ` +
        "Redemptions pull from this account, so without these approvals every exit reverts.",
    })}`,
  );
}

log("");
log(`Recovered from the chain. Confirm it with:  pnpm verify-deployment --network ${connection.networkName}`);
log("(add EXPECT_LIVE=1 if the deployment is already unpaused)");
