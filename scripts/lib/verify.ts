/**
 * Run after the multisig has executed the grant batch and before anything is unpaused. The
 * checks target a HALF-FINISHED handover — some roles granted, the scheduled critical grant
 * forgotten, the payment tokens never registered — which looks fine on the surface.
 *
 * Two rules this file follows:
 *
 *   1. EXACT MEMBERSHIP, NOT PRESENCE. "The RedemptionVault holds REFUND_VAULT_ROLE" is
 *      nearly worthless; "nobody else holds it" is the claim that matters, and it needs
 *      enumeration. An extra FEED_ADMIN slipped into the batch passes a `length > 0` check
 *      while being able to post emergency NAV past the deviation cap.
 *
 *   2. A CHECK THAT CANNOT FAIL IS WORSE THAN NO CHECK. The initialisability probe used one
 *      hardcoded signature for every implementation; against a contract with a different
 *      initializer it hit a non-existent function, reverted, and recorded a PASS.
 */
import type { ChainType, NetworkConnection } from "hardhat/types/network";
import { getAddress, type Address } from "viem";

import {
  OP_IDS,
  ROLE_IDS,
  ROLE_SEPARATION_RULES,
  type AddressBook,
  type OperationalHolders,
} from "./deployment.js";
import type { PlatformConfig } from "../config.js";

/**
 * `NetworkConnection` is invariant in its type parameter, so one created as
 * `NetworkConnection<"l1">` is not assignable to the default `<"generic">`. These helpers
 * care about none of that.
 */
type AnyNetworkConnection = NetworkConnection<ChainType | string>;

export interface VerificationReport {
  passed: boolean;
  checks: { name: string; ok: boolean; detail?: string }[];
}

export interface VerifyOptions {
  /** Expect every operation to still be paused. False once the handover has completed. */
  expectPaused: boolean;
  /** Expected operational role holders. Membership is asserted EXACTLY against these. */
  holders: OperationalHolders;
  /** The configuration the deployment was supposed to receive. */
  config: PlatformConfig;
}

const ACCESS_REGISTRY_ABI = [
  { type: "function", name: "hasRole", inputs: [{ name: "role", type: "bytes32" }, { name: "account", type: "address" }], outputs: [{ type: "bool" }], stateMutability: "view" },
  { type: "function", name: "getRoleMembers", inputs: [{ name: "role", type: "bytes32" }], outputs: [{ type: "address[]" }], stateMutability: "view" },
  { type: "function", name: "getRoleAdmin", inputs: [{ name: "role", type: "bytes32" }], outputs: [{ type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "defaultAdmin", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
  { type: "function", name: "defaultAdminDelay", inputs: [], outputs: [{ type: "uint48" }], stateMutability: "view" },
] as const;

const TIMELOCK_ABI = [
  { type: "function", name: "getMinDelay", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "hasRole", inputs: [{ name: "role", type: "bytes32" }, { name: "account", type: "address" }], outputs: [{ type: "bool" }], stateMutability: "view" },
  { type: "function", name: "PROPOSER_ROLE", inputs: [], outputs: [{ type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "EXECUTOR_ROLE", inputs: [], outputs: [{ type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "CANCELLER_ROLE", inputs: [], outputs: [{ type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "DEFAULT_ADMIN_ROLE", inputs: [], outputs: [{ type: "bytes32" }], stateMutability: "view" },
] as const;

const PAUSABLE_ABI = [
  { type: "function", name: "isOperationPaused", inputs: [{ name: "opId", type: "bytes32" }], outputs: [{ type: "bool" }], stateMutability: "view" },
] as const;

const ZERO = "0x0000000000000000000000000000000000000000" as const;

/**
 * Independent of any config. docs/TRUST-MODEL.md quantifies the blast radius of a compromised
 * multisig as "days until a countermeasure lands", and that number is this delay: a fork may
 * raise it, but lowering it invalidates the published risk statement.
 */
const MIN_ACCEPTABLE_TIMELOCK_DELAY = 48n * 60n * 60n;
const ERC1967_IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" as const;

type Recorder = (name: string, ok: boolean, detail?: string) => void;

export async function verifyDeployment(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
  options: VerifyOptions,
): Promise<VerificationReport> {
  const publicClient = await connection.viem.getPublicClient();
  const checks: VerificationReport["checks"] = [];

  const record: Recorder = (name, ok, detail) => {
    checks.push({ name, ok, ...(detail === undefined ? {} : { detail }) });
  };

  const readRegistry = async <T>(functionName: string, args: unknown[]): Promise<T> =>
    (await publicClient.readContract({
      address: addresses.accessRegistry,
      abi: ACCESS_REGISTRY_ABI,
      functionName: functionName as "hasRole",
      args: args as never,
    })) as T;

  const members = async (role: `0x${string}`): Promise<Address[]> =>
    (await readRegistry<Address[]>("getRoleMembers", [role])).map((a) => getAddress(a));

  /** Asserts the FULL membership of a role, not merely that someone holds it. */
  const expectExactly = async (label: string, role: `0x${string}`, expected: Address[]) => {
    const actual = await members(role);
    const want = [...new Set(expected.map((a) => getAddress(a)))].sort();
    const got = [...actual].sort();
    const ok = want.length === got.length && want.every((a, i) => a === got[i]);
    record(
      `${label}: held by exactly the expected ${want.length} account(s)`,
      ok,
      ok ? undefined : `expected ${want.join(", ") || "(nobody)"}, found ${got.join(", ") || "(nobody)"}`,
    );
  };

  /* ---------------------- Critical role hierarchy ---------------------- */

  const admin = getAddress(await readRegistry<Address>("defaultAdmin", []));
  record("DEFAULT_ADMIN is the configured admin", admin === getAddress(addresses.admin), `found ${admin}`);

  // Equal delays: if admin rotation were slower, an attacker holding the multisig could push
  // a critical change through before a legitimate rotation completed.
  const adminDelay = await readRegistry<bigint>("defaultAdminDelay", []);
  record(
    "admin-transfer delay equals the timelock delay",
    BigInt(adminDelay) === options.config.timelockDelaySeconds,
    `${adminDelay}s vs timelock ${options.config.timelockDelaySeconds}s`,
  );

  for (const [label, role] of [
    ["TIMELOCK_ADMIN", ROLE_IDS.TIMELOCK_ADMIN],
    ["UPGRADER", ROLE_IDS.UPGRADER],
    ["CRITICAL_CONFIG", ROLE_IDS.CRITICAL_CONFIG],
    ["REFUND_VAULT", ROLE_IDS.REFUND_VAULT],
    ["ENFORCER", ROLE_IDS.ENFORCER],
  ] as const) {
    const roleAdmin = await readRegistry<`0x${string}`>("getRoleAdmin", [role]);
    record(
      `${label} is administered by TIMELOCK_ADMIN`,
      roleAdmin.toLowerCase() === ROLE_IDS.TIMELOCK_ADMIN.toLowerCase(),
      `found ${roleAdmin}`,
    );
  }

  await expectExactly("TIMELOCK_ADMIN", ROLE_IDS.TIMELOCK_ADMIN, [addresses.timelock]);
  await expectExactly("UPGRADER", ROLE_IDS.UPGRADER, [addresses.timelock]);
  await expectExactly("CRITICAL_CONFIG", ROLE_IDS.CRITICAL_CONFIG, [addresses.timelock]);

  // The claim that matters about the carve-out: any second holder is a second bypass of the
  // transfer pause.
  await expectExactly("REFUND_VAULT", ROLE_IDS.REFUND_VAULT, [addresses.redemptionVault]);

  // Confiscation powers are granted to nobody at deployment, on purpose.
  await expectExactly("ENFORCER", ROLE_IDS.ENFORCER, []);

  /* ------------------------ Mint / burn boundary ----------------------- */

  await expectExactly("MINTER", ROLE_IDS.MINTER, [addresses.depositVault]);
  await expectExactly("BURNER", ROLE_IDS.BURNER, [addresses.redemptionVault]);

  for (const [label, role, account] of [
    ["DepositVault does NOT hold BURNER", ROLE_IDS.BURNER, addresses.depositVault],
    ["RedemptionVault does NOT hold MINTER", ROLE_IDS.MINTER, addresses.redemptionVault],
    ["DepositVault does NOT hold REFUND_VAULT", ROLE_IDS.REFUND_VAULT, addresses.depositVault],
  ] as const) {
    record(label, !(await readRegistry<boolean>("hasRole", [role, account])));
  }

  /* ---------- Operational roles: exact membership, not presence ---------- */

  const operational: [string, `0x${string}`, Address][] = [
    ["COMPLIANCE_ADMIN", ROLE_IDS.COMPLIANCE_ADMIN, options.holders.complianceAdmin],
    ["GREENLIST_OPERATOR", ROLE_IDS.GREENLIST_OPERATOR, options.holders.greenlistOperator],
    ["BLACKLIST_OPERATOR", ROLE_IDS.BLACKLIST_OPERATOR, options.holders.blacklistOperator],
    ["REQUEST_OPERATOR", ROLE_IDS.REQUEST_OPERATOR, options.holders.requestOperator],
    ["VAULT_ADMIN", ROLE_IDS.VAULT_ADMIN, options.holders.vaultAdmin],
    ["FEED_OPERATOR", ROLE_IDS.FEED_OPERATOR, options.holders.feedOperator],
    ["FEED_ADMIN", ROLE_IDS.FEED_ADMIN, options.holders.feedAdmin],
    ["PAUSER", ROLE_IDS.PAUSER, options.holders.pauser],
    ["UNPAUSER", ROLE_IDS.UNPAUSER, options.holders.unpauser],
  ];
  for (const [label, role, expected] of operational) {
    await expectExactly(label, role, [expected]);
  }

  // Least privilege is a property of the ASSIGNMENT, not the contracts: a fork that collapses
  // two roles onto one key still passes every membership check above.
  for (const [a, b] of ROLE_SEPARATION_RULES) {
    const separated = getAddress(options.holders[a]) !== getAddress(options.holders[b]);
    record(
      `${a} and ${b} are held by different accounts`,
      separated,
      separated ? undefined : `both are ${options.holders[a]}`,
    );
  }

  /* --------------------------- The timelock itself --------------------------- */

  const readTimelock = async <T>(functionName: string, args: unknown[] = []): Promise<T> =>
    (await publicClient.readContract({
      address: addresses.timelock,
      abi: TIMELOCK_ABI,
      functionName: functionName as "getMinDelay",
      args: args as never,
    })) as T;

  const minDelay = await readTimelock<bigint>("getMinDelay");
  record(
    "timelock minDelay matches the configuration",
    minDelay === options.config.timelockDelaySeconds,
    `${minDelay}s`,
  );
  // An ABSOLUTE floor as well: comparing only against the config would accept a fork that
  // lowered the delay in both places at once, the two values agreeing while the window shrank.
  record(
    "timelock minDelay is at least the 48h the trust model assumes",
    minDelay >= MIN_ACCEPTABLE_TIMELOCK_DELAY,
    `${minDelay}s vs floor ${MIN_ACCEPTABLE_TIMELOCK_DELAY}s`,
  );

  const proposerRole = await readTimelock<`0x${string}`>("PROPOSER_ROLE");
  const executorRole = await readTimelock<`0x${string}`>("EXECUTOR_ROLE");
  const cancellerRole = await readTimelock<`0x${string}`>("CANCELLER_ROLE");
  const timelockAdminRole = await readTimelock<`0x${string}`>("DEFAULT_ADMIN_ROLE");

  record(
    "timelock proposer is the admin multisig",
    await readTimelock<boolean>("hasRole", [proposerRole, addresses.admin]),
  );
  record(
    "timelock canceller is the admin multisig",
    await readTimelock<boolean>("hasRole", [cancellerRole, addresses.admin]),
  );
  // An open executor means a matured, publicly visible proposal cannot be withheld by
  // whoever proposed it.
  record(
    "timelock executor is open to anyone",
    await readTimelock<boolean>("hasRole", [executorRole, ZERO]),
  );
  // OZ's TimelockController grants DEFAULT_ADMIN to ITSELF, so changes to its own role set
  // pass through the delay. The dangerous case is an EXTERNAL admin, which could re-grant
  // PROPOSER or EXECUTOR immediately and dissolve the delay. Every plausible candidate is
  // checked: the likeliest mistake is leaving it as the DEPLOYER, which a single-candidate
  // check would sail past.
  const adminCandidates: [string, Address][] = [
    ["the admin multisig", addresses.admin],
    ["the treasury", addresses.treasury],
    ...(Object.entries(options.holders) as [string, Address][]),
  ];
  const externalAdmins: string[] = [];
  for (const [label, candidate] of adminCandidates) {
    if (await readTimelock<boolean>("hasRole", [timelockAdminRole, candidate])) {
      externalAdmins.push(`${label} (${candidate})`);
    }
  }
  record(
    "timelock has no EXTERNAL admin (only itself)",
    externalAdmins.length === 0,
    externalAdmins.length === 0 ? undefined : `held by ${externalAdmins.join(", ")}`,
  );

  /* --------------------------- Pause posture --------------------------- */

  const pauseTargets: [string, Address, `0x${string}`][] = [
    ["DepositVault/DEPOSIT_INSTANT", addresses.depositVault, OP_IDS.DEPOSIT_INSTANT],
    ["DepositVault/DEPOSIT_REQUEST", addresses.depositVault, OP_IDS.DEPOSIT_REQUEST],
    ["RedemptionVault/REDEEM_INSTANT", addresses.redemptionVault, OP_IDS.REDEEM_INSTANT],
    ["RedemptionVault/REDEEM_REQUEST", addresses.redemptionVault, OP_IDS.REDEEM_REQUEST],
    ["Token/TRANSFER", addresses.token, OP_IDS.TRANSFER],
    ["Aggregator/ORACLE_UPDATE", addresses.aggregator, OP_IDS.ORACLE_UPDATE],
  ];

  for (const [label, target, opId] of pauseTargets) {
    const paused = (await publicClient.readContract({
      address: target,
      abi: PAUSABLE_ABI,
      functionName: "isOperationPaused",
      args: [opId],
    })) as boolean;

    record(
      options.expectPaused ? `${label} is still paused` : `${label} is live`,
      paused === options.expectPaused,
      `paused = ${paused}`,
    );
  }

  await lintConfiguration(connection, addresses, options, record);
  await probeImplementations(connection, addresses, options, record);

  return { passed: checks.every((check) => check.ok), checks };
}

/**
 * Roles being right says nothing about the parameters. A deployment can have a flawless
 * privilege graph and still point a vault at the wrong feed, start with the greenlist open,
 * or register no payment tokens at all.
 */
async function lintConfiguration(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
  options: VerifyOptions,
  record: Recorder,
): Promise<void> {
  const publicClient = await connection.viem.getPublicClient();
  const at = async <N extends string>(name: N, address: Address) =>
    connection.viem.getContractAt(name, address, { client: { public: publicClient } });

  const compliance = await at("ComplianceRegistry", addresses.complianceRegistry);
  const token = await at("WbondToken", addresses.token);
  const dataFeed = await at("DataFeed", addresses.dataFeed);
  const aggregator = await at("AdminNavAggregator", addresses.aggregator);
  const depositVault = await at("DepositVault", addresses.depositVault);
  const redemptionVault = await at("RedemptionVault", addresses.redemptionVault);

  const sameAddress = (label: string, actual: unknown, expected: unknown) =>
    record(label, String(actual).toLowerCase() === String(expected).toLowerCase(), `found ${actual}`);

  record(
    "greenlist enforcement matches the configuration",
    (await compliance.read.greenlistEnabled()) === options.config.compliance.greenlistEnabled,
  );
  sameAddress(
    "sanctions oracle is the configured address",
    await compliance.read.sanctionsOracle(),
    options.config.compliance.sanctionsOracle,
  );

  // A contract pointed at a stale registry is a split-brain compliance failure no
  // single-contract test can see.
  sameAddress("token -> AccessRegistry", await token.read.accessRegistry(), addresses.accessRegistry);
  sameAddress("token -> ComplianceRegistry", await token.read.complianceRegistry(), addresses.complianceRegistry);
  sameAddress("DataFeed -> aggregator", await dataFeed.read.aggregator(), addresses.aggregator);

  for (const [label, vault] of [
    ["DepositVault", depositVault],
    ["RedemptionVault", redemptionVault],
  ] as const) {
    sameAddress(`${label} -> token`, await vault.read.rwaToken(), addresses.token);
    sameAddress(`${label} -> DataFeed`, await vault.read.dataFeed(), addresses.dataFeed);
    sameAddress(
      `${label} -> ComplianceRegistry`,
      await vault.read.complianceRegistry(),
      addresses.complianceRegistry,
    );

    // EXACTNESS, not merely non-zero: `tokensReceiver` is where every user deposit lands, and
    // "some non-zero address" includes an attacker's.
    for (const [name, value] of [
      ["tokensReceiver", await vault.read.tokensReceiver()],
      ["feeReceiver", await vault.read.feeReceiver()],
      ["blockedFundsReceiver", await vault.read.blockedFundsReceiver()],
    ] as const) {
      sameAddress(`${label}.${name} is the expected treasury`, value, addresses.treasury);
    }
  }

  sameAddress(
    "RedemptionVault -> tokensProvider",
    await redemptionVault.read.tokensProvider(),
    addresses.treasury,
  );

  // The two bound sets live in different units and must describe the SAME band: a mismatch
  // means the aggregator accepts prices the DataFeed then refuses — healthy to the operator,
  // dead to the vaults.
  const [navMin, navMax] = await aggregator.read.hardBounds();
  const [wadMin, wadMax] = await dataFeed.read.priceBounds();
  const feedDecimals = await aggregator.read.decimals();
  const scale = 10n ** (18n - BigInt(feedDecimals));
  record(
    "aggregator hard bounds and DataFeed price bounds describe the same band",
    BigInt(navMin) * scale === wadMin && BigInt(navMax) * scale === wadMax,
    `[${navMin}, ${navMax}] scaled by 1e${18 - Number(feedDecimals)} vs [${wadMin}, ${wadMax}]`,
  );

  const registered = await depositVault.read.paymentTokens();
  record(
    "at least one payment token is registered",
    registered.length > 0,
    `${registered.length} registered`,
  );

  // Naming the vacuous case: with an empty list the loop below asserts nothing, and a green
  // report would be indistinguishable from "all the token checks passed".
  record(
    "the configured payment-token list is non-empty",
    options.config.paymentTokens.length > 0,
    `${options.config.paymentTokens.length} configured — per-token checks below are ` +
      "vacuous when this is zero",
  );

  for (const expected of options.config.paymentTokens) {
    for (const [label, vault] of [
      ["DepositVault", depositVault],
      ["RedemptionVault", redemptionVault],
    ] as const) {
      const tokenConfig = await vault.read.paymentTokenConfig([expected.address]);
      record(
        `${label}: ${expected.address} is registered and enabled`,
        tokenConfig.registered && tokenConfig.enabled,
      );
    }

    // Redemptions pull from the provider, so a missing approval makes every exit revert.
    const erc20 = await at("MockERC20", expected.address);
    const allowance = await erc20.read.allowance([addresses.treasury, addresses.redemptionVault]);
    record(
      `tokensProvider has approved the RedemptionVault for ${expected.address}`,
      allowance > 0n,
      `allowance ${allowance}`,
    );
  }
}

/**
 * An implementation that accepts `initialize` is a takeover vector: whoever calls it can
 * upgrade it out from under every proxy. Each probe uses the contract's REAL ABI and accepts
 * only `InvalidInitialization` as proof — see rule 2 at the top of this file.
 */
async function probeImplementations(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
  options: VerifyOptions,
  record: Recorder,
): Promise<void> {
  const publicClient = await connection.viem.getPublicClient();

  const vaultParams = {
    registry: addresses.accessRegistry,
    rwaToken: addresses.token,
    dataFeed: addresses.dataFeed,
    complianceRegistry: addresses.complianceRegistry,
    tokensReceiver: addresses.treasury,
    feeReceiver: addresses.treasury,
    blockedFundsReceiver: addresses.treasury,
    instantFeeBps: options.config.vault.instantFeeBps,
    instantDailyLimitWad: options.config.vault.instantDailyLimitWad,
    minAmountWad: options.config.vault.minAmountWad,
    minFirstAmountWad: options.config.vault.minFirstAmountWad,
    variationToleranceBps: options.config.vault.variationToleranceBps,
    startPaused: true,
  } as const;

  const probes: [string, Address, readonly unknown[]][] = [
    ["AccessRegistry", addresses.accessRegistry, [addresses.admin, addresses.timelock]],
    [
      "ComplianceRegistry",
      addresses.complianceRegistry,
      [addresses.accessRegistry, options.config.compliance.sanctionsOracle, true],
    ],
    [
      "AdminNavAggregator",
      addresses.aggregator,
      [
        addresses.accessRegistry,
        8,
        options.config.oracle.initialAnswer,
        options.config.oracle.minAnswer,
        options.config.oracle.maxAnswer,
        options.config.oracle.deviationBps,
        options.config.oracle.updateCooldownSeconds,
        true,
      ],
    ],
    [
      "DataFeed",
      addresses.dataFeed,
      [
        addresses.accessRegistry,
        addresses.aggregator,
        options.config.oracle.healthyDiffSeconds,
        options.config.oracle.minPriceWad,
        options.config.oracle.maxPriceWad,
      ],
    ],
    ["WbondToken", addresses.token, [addresses.accessRegistry, addresses.complianceRegistry, true]],
    ["DepositVault", addresses.depositVault, [vaultParams, options.config.vault.maxSupplyCapWad]],
    ["RedemptionVault", addresses.redemptionVault, [vaultParams, addresses.treasury]],
  ];

  for (const [name, proxy, args] of probes) {
    const raw = await publicClient.getStorageAt({
      address: proxy,
      slot: ERC1967_IMPLEMENTATION_SLOT,
    });
    if (raw === undefined) {
      record(`${name} implementation cannot be initialised`, false, "no ERC-1967 slot");
      continue;
    }
    const implementation = getAddress(`0x${raw.slice(-40)}`);

    const contract = await connection.viem.getContractAt(name, implementation, {
      client: { public: publicClient },
    });
    const simulate = contract.simulate as unknown as Record<
      string,
      (a: readonly unknown[]) => Promise<unknown>
    >;

    let outcome = "the call SUCCEEDED";
    try {
      const initialize = simulate["initialize"];
      if (initialize === undefined) {
        outcome = "no initialize in the ABI — probe is wrong, not the contract";
      } else {
        await initialize(args);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      outcome = /InvalidInitialization/.test(message)
        ? "InvalidInitialization"
        : `reverted for another reason: ${message.split("\n")[0]}`;
    }

    record(
      `${name} implementation cannot be initialised`,
      outcome === "InvalidInitialization",
      `${implementation} — ${outcome}`,
    );
  }
}

export function printReport(report: VerificationReport, log: (message: string) => void): void {
  for (const check of report.checks) {
    const mark = check.ok ? "PASS" : "FAIL";
    log(`  [${mark}] ${check.name}${check.detail === undefined ? "" : `  (${check.detail})`}`);
  }
  log("");
  log(report.passed ? "VERIFICATION PASSED" : "VERIFICATION FAILED");
}
