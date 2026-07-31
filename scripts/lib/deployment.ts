/**
 * Deployment graph, address book and role-grant batch. Shared by `deploy.ts`,
 * `verify-deployment.ts` and the integration tests, so all three exercise the same wiring: a
 * test reproducing the graph by hand would stop proving anything about what deploy produces.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { upgrades } from "@openzeppelin/hardhat-upgrades/viem";
import type { HardhatRuntimeEnvironment } from "hardhat/types/hre";
import type { ChainType, NetworkConnection } from "hardhat/types/network";
import { encodeFunctionData, getAddress, keccak256, toHex, type Address } from "viem";

import { REFERENCE_CONFIG, FEED_DECIMALS, type PlatformConfig } from "../config.js";

/**
 * `NetworkConnection` is invariant in its type parameter, so one created as
 * `NetworkConnection<"l1">` is not assignable to the default `<"generic">`. These helpers
 * care about none of that.
 */
type AnyNetworkConnection = NetworkConnection<ChainType | string>;


/**
 * The plugin types its parameter as the default `NetworkConnection<"generic">`, which is
 * invariant, so a connection with an explicit chain type does not fit. Nothing in the plugin
 * depends on the chain type, so the cast is confined here rather than repeated per call site.
 */
export async function upgradesFor(
  hre: HardhatRuntimeEnvironment,
  connection: AnyNetworkConnection,
): Promise<Awaited<ReturnType<typeof upgrades>>> {
  return upgrades(hre, connection as Parameters<typeof upgrades>[1]);
}

/** Role ids, derived exactly as `contracts/access/Roles.sol` derives them. */
export const ROLE_IDS = {
  TIMELOCK_ADMIN: keccak256(toHex("rwa.role.TIMELOCK_ADMIN")),
  UPGRADER: keccak256(toHex("rwa.role.UPGRADER")),
  CRITICAL_CONFIG: keccak256(toHex("rwa.role.CRITICAL_CONFIG")),
  REFUND_VAULT: keccak256(toHex("rwa.role.REFUND_VAULT")),
  ENFORCER: keccak256(toHex("rwa.role.ENFORCER")),
  COMPLIANCE_ADMIN: keccak256(toHex("rwa.role.COMPLIANCE_ADMIN")),
  GREENLIST_OPERATOR: keccak256(toHex("rwa.role.GREENLIST_OPERATOR")),
  BLACKLIST_OPERATOR: keccak256(toHex("rwa.role.BLACKLIST_OPERATOR")),
  REQUEST_OPERATOR: keccak256(toHex("rwa.role.REQUEST_OPERATOR")),
  VAULT_ADMIN: keccak256(toHex("rwa.role.VAULT_ADMIN")),
  FEED_OPERATOR: keccak256(toHex("rwa.role.FEED_OPERATOR")),
  FEED_ADMIN: keccak256(toHex("rwa.role.FEED_ADMIN")),
  PAUSER: keccak256(toHex("rwa.role.PAUSER")),
  UNPAUSER: keccak256(toHex("rwa.role.UNPAUSER")),
  MINTER: keccak256(toHex("rwa.role.MINTER")),
  BURNER: keccak256(toHex("rwa.role.BURNER")),
} as const;

export const OP_IDS = {
  DEPOSIT_INSTANT: keccak256(toHex("rwa.op.DEPOSIT_INSTANT")),
  DEPOSIT_REQUEST: keccak256(toHex("rwa.op.DEPOSIT_REQUEST")),
  REDEEM_INSTANT: keccak256(toHex("rwa.op.REDEEM_INSTANT")),
  REDEEM_REQUEST: keccak256(toHex("rwa.op.REDEEM_REQUEST")),
  TRANSFER: keccak256(toHex("rwa.op.TRANSFER")),
  ORACLE_UPDATE: keccak256(toHex("rwa.op.ORACLE_UPDATE")),
} as const;

export interface OperationalHolders {
  complianceAdmin: Address;
  greenlistOperator: Address;
  blacklistOperator: Address;
  requestOperator: Address;
  vaultAdmin: Address;
  feedOperator: Address;
  feedAdmin: Address;
  pauser: Address;
  unpauser: Address;
}

export interface AddressBook {
  network: string;
  admin: Address;
  timelock: Address;
  accessRegistry: Address;
  complianceRegistry: Address;
  aggregator: Address;
  dataFeed: Address;
  token: Address;
  depositVault: Address;
  redemptionVault: Address;
  paymentToken: Address;
  treasury: Address;
}

/** One entry of a Safe Transaction Builder batch. */
export interface SafeTransaction {
  to: Address;
  value: "0";
  data: `0x${string}`;
  description: string;
}

export interface DeploymentResult {
  addresses: AddressBook;
  /** The role assignment this deployment expects. Feed it straight to verification. */
  holders: OperationalHolders;
  /** The configuration actually used, including any locally deployed mock token. */
  config: PlatformConfig;
  /** Entries the admin multisig executes. */
  grants: SafeTransaction[];
  /**
   * One `approve` per payment token, emitted whether or not the treasury is the multisig.
   * An `approve` is authorised by `msg.sender`, and the configuration in which folding them
   * together is WRONG is the one nobody would notice — so the split must not depend on
   * noticing.
   */
  treasuryActions: SafeTransaction[];
}

export interface DeployOptions {
  /** The account that ends up holding `DEFAULT_ADMIN_ROLE`. Never the deployer in production. */
  admin: Address;
  /** Deploy a mock USDC and treasury float. Local development only. */
  deployMockPaymentToken: boolean;
  /** Defaults to the config's `operationalHolders`, falling back to the admin when unset. */
  holders?: OperationalHolders;
  config?: PlatformConfig;
  log?: (message: string) => void;
}

/**
 * The TimelockController goes FIRST because the AccessRegistry takes its address as an
 * initialiser parameter and offers no setter: that is what makes the critical role hierarchy
 * immutable. Everything lands PAUSED with the greenlist enforced, so nothing can move user
 * funds before `verify-deployment` confirms the wiring.
 */
export async function deployPlatform(
  hre: HardhatRuntimeEnvironment,
  connection: AnyNetworkConnection,
  options: DeployOptions,
): Promise<DeploymentResult> {
  const config = options.config ?? REFERENCE_CONFIG;
  const log = options.log ?? (() => {});
  const api = await upgradesFor(hre, connection);
  const { viem } = connection;

  const [deployer] = await viem.getWalletClients();
  if (deployer === undefined) throw new Error("no wallet client available");

  // 1. Timelock first — the registry needs its address and will never accept another.
  const timelock = await viem.deployContract("RwaTimelockController", [
    config.timelockDelaySeconds,
    [options.admin], // proposer, and automatically canceller
    ["0x0000000000000000000000000000000000000000"], // open executor
    "0x0000000000000000000000000000000000000000", // no admin: the role set is final
  ]);
  log(`TimelockController      ${timelock.address}`);

  const accessRegistry = await api.deployProxy(
    "AccessRegistry",
    [options.admin, timelock.address],
    { kind: "uups" },
  );
  log(`AccessRegistry         ${accessRegistry.address}`);

  const complianceRegistry = await api.deployProxy(
    "ComplianceRegistry",
    [accessRegistry.address, config.compliance.sanctionsOracle, config.compliance.greenlistEnabled],
    { kind: "uups" },
  );
  log(`ComplianceRegistry     ${complianceRegistry.address}`);

  const aggregator = await api.deployProxy(
    "AdminNavAggregator",
    [
      accessRegistry.address,
      FEED_DECIMALS,
      config.oracle.initialAnswer,
      config.oracle.minAnswer,
      config.oracle.maxAnswer,
      config.oracle.deviationBps,
      config.oracle.updateCooldownSeconds,
      true, // NAV posting starts paused
    ],
    { kind: "uups" },
  );
  log(`AdminNavAggregator     ${aggregator.address}`);

  const dataFeed = await api.deployProxy(
    "DataFeed",
    [
      accessRegistry.address,
      aggregator.address,
      config.oracle.healthyDiffSeconds,
      config.oracle.minPriceWad,
      config.oracle.maxPriceWad,
    ],
    { kind: "uups" },
  );
  log(`DataFeed               ${dataFeed.address}`);

  const token = await api.deployProxy(
    "WbondToken",
    [accessRegistry.address, complianceRegistry.address, true],
    { kind: "uups" },
  );
  log(`WbondToken             ${token.address}`);

  // The treasury both receives deposits and funds redemptions, and is separable from the
  // admin — the handover changes shape when it differs. See {buildGrantBatch}.
  const treasury = config.treasury ?? options.admin;

  const vaultParams = {
    registry: accessRegistry.address,
    rwaToken: token.address,
    dataFeed: dataFeed.address,
    complianceRegistry: complianceRegistry.address,
    tokensReceiver: treasury,
    feeReceiver: treasury,
    blockedFundsReceiver: treasury,
    instantFeeBps: config.vault.instantFeeBps,
    instantDailyLimitWad: config.vault.instantDailyLimitWad,
    minAmountWad: config.vault.minAmountWad,
    minFirstAmountWad: config.vault.minFirstAmountWad,
    variationToleranceBps: config.vault.variationToleranceBps,
    startPaused: true,
  } as const;

  const depositVault = await api.deployProxy(
    "DepositVault",
    [vaultParams, config.vault.maxSupplyCapWad],
    { kind: "uups" },
  );
  log(`DepositVault           ${depositVault.address}`);

  const redemptionVault = await api.deployProxy(
    "RedemptionVault",
    [vaultParams, treasury],
    { kind: "uups" },
  );
  log(`RedemptionVault        ${redemptionVault.address}`);

  // The mock joins the configured payment tokens so the grant batch registers it through the
  // same path a real stablecoin takes; registering it out-of-band would leave that half of
  // the batch untested.
  let effectiveConfig = config;
  let paymentToken: Address = "0x0000000000000000000000000000000000000000";
  if (options.deployMockPaymentToken) {
    const mock = await viem.deployContract("MockERC20", ["USD Coin", "USDC", 6]);
    paymentToken = mock.address;
    effectiveConfig = {
      ...config,
      paymentTokens: [
        ...config.paymentTokens,
        { address: paymentToken, feeBps: 0n, allowanceWad: 2n ** 256n - 1n },
      ],
    };
    log(`MockERC20 (USDC)       ${paymentToken}`);
  }

  const addresses: AddressBook = {
    network: connection.networkName,
    admin: options.admin,
    timelock: timelock.address,
    accessRegistry: accessRegistry.address,
    complianceRegistry: complianceRegistry.address,
    aggregator: aggregator.address,
    dataFeed: dataFeed.address,
    token: token.address,
    depositVault: depositVault.address,
    redemptionVault: redemptionVault.address,
    paymentToken,
    treasury,
  };

  const holders = options.holders ?? resolveOperationalHolders(options.admin, config);
  assertRoleSeparation(holders);

  const batch = buildGrantBatch(addresses, holders, effectiveConfig);

  return {
    addresses,
    holders,
    config: effectiveConfig,
    grants: batch.multisig,
    treasuryActions: batch.treasury,
  };
}

/**
 * Every operational role on one address: the local-development shape, and explicitly NOT a
 * recommendation — it puts PAUSER and UNPAUSER on the same key, making the circuit breaker
 * self-resettable. Production supplies per-role addresses via `config.operationalHolders`.
 */
export function defaultOperationalHolders(admin: Address): OperationalHolders {
  return {
    complianceAdmin: admin,
    greenlistOperator: admin,
    blacklistOperator: admin,
    requestOperator: admin,
    vaultAdmin: admin,
    feedOperator: admin,
    feedAdmin: admin,
    pauser: admin,
    unpauser: admin,
  };
}

/** Config-declared holders, with the admin filling anything left unset. */
export function resolveOperationalHolders(
  admin: Address,
  config: PlatformConfig,
): OperationalHolders {
  return { ...defaultOperationalHolders(admin), ...(config.operationalHolders ?? {}) };
}

/**
 * PAUSER/UNPAUSER: a hot key that can both stop and restart the system is not a circuit
 * breaker. REQUEST_OPERATOR/VAULT_ADMIN: the account that moves user funds must not also set
 * the limits those movements are checked against.
 */
export const ROLE_SEPARATION_RULES: [keyof OperationalHolders, keyof OperationalHolders][] = [
  ["pauser", "unpauser"],
  ["requestOperator", "vaultAdmin"],
];

/**
 * Checked at DEPLOY time, not only at audit time: writing a `grants.json` that provably
 * cannot pass its own audit wastes a multisig ceremony and a delay before anyone finds out.
 */
export function assertRoleSeparation(holders: OperationalHolders): void {
  for (const [a, b] of ROLE_SEPARATION_RULES) {
    if (getAddress(holders[a]) === getAddress(holders[b])) {
      throw new Error(
        `${a} and ${b} must be different accounts (both are ${holders[a]}). ` +
          "Set them separately in config.operationalHolders — see docs/FORKING.md §1.3.",
      );
    }
  }
}

const GRANT_ROLE_ABI = [
  {
    type: "function",
    name: "grantRole",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "account", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

const TIMELOCK_SCHEDULE_ABI = [
  {
    type: "function",
    name: "schedule",
    inputs: [
      { name: "target", type: "address" },
      { name: "value", type: "uint256" },
      { name: "data", type: "bytes" },
      { name: "predecessor", type: "bytes32" },
      { name: "salt", type: "bytes32" },
      { name: "delay", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

const ADD_PAYMENT_TOKEN_ABI = [
  {
    type: "function",
    name: "addPaymentToken",
    inputs: [
      { name: "token", type: "address" },
      { name: "feeBps", type: "uint256" },
      { name: "allowanceWad", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

const ERC20_APPROVE_ABI = [
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
] as const;

const EMPTY_BYTES32 = `0x${"0".repeat(64)}` as `0x${string}`;
const MAX_UINT256 = 2n ** 256n - 1n;

/**
 * Two kinds of entry, which is not cosmetic:
 *
 *   - OPERATIONAL grants execute immediately; the multisig is DEFAULT_ADMIN.
 *   - REFUND_VAULT_ROLE is CRITICAL, administered by TIMELOCK_ADMIN_ROLE, so it cannot be
 *     granted directly at all — the entry is a `schedule` call and someone must return
 *     after the delay to execute it.
 *
 * A fork that "simplifies" the second into a direct grant will find it reverts.
 */
export function buildGrantBatch(
  addresses: AddressBook,
  holders: OperationalHolders,
  config: PlatformConfig,
): { multisig: SafeTransaction[]; treasury: SafeTransaction[] } {
  const grant = (role: `0x${string}`, account: Address, description: string): SafeTransaction => ({
    to: addresses.accessRegistry,
    value: "0",
    data: encodeFunctionData({ abi: GRANT_ROLE_ABI, functionName: "grantRole", args: [role, account] }),
    description,
  });

  const operational: SafeTransaction[] = [
    grant(ROLE_IDS.MINTER, addresses.depositVault, "MINTER -> DepositVault"),
    grant(ROLE_IDS.BURNER, addresses.redemptionVault, "BURNER -> RedemptionVault"),
    grant(ROLE_IDS.COMPLIANCE_ADMIN, holders.complianceAdmin, "COMPLIANCE_ADMIN"),
    grant(ROLE_IDS.GREENLIST_OPERATOR, holders.greenlistOperator, "GREENLIST_OPERATOR"),
    grant(ROLE_IDS.BLACKLIST_OPERATOR, holders.blacklistOperator, "BLACKLIST_OPERATOR"),
    grant(ROLE_IDS.REQUEST_OPERATOR, holders.requestOperator, "REQUEST_OPERATOR"),
    grant(ROLE_IDS.VAULT_ADMIN, holders.vaultAdmin, "VAULT_ADMIN"),
    grant(ROLE_IDS.FEED_OPERATOR, holders.feedOperator, "FEED_OPERATOR"),
    grant(ROLE_IDS.FEED_ADMIN, holders.feedAdmin, "FEED_ADMIN"),
    grant(ROLE_IDS.PAUSER, holders.pauser, "PAUSER"),
    grant(ROLE_IDS.UNPAUSER, holders.unpauser, "UNPAUSER"),
  ];

  // `addPaymentToken` is `onlyRegistryRole(vaultAdminRole())` and the batch executes as the
  // multisig, so those entries are valid only while VAULT_ADMIN sits there. Splitting it off
  // — which ROLE_SEPARATION_RULES encourages — makes entries revert and takes the whole
  // MultiSend down. Fail at build time with the coupling named.
  if (config.paymentTokens.length > 0 && getAddress(holders.vaultAdmin) !== getAddress(addresses.admin)) {
    throw new Error(
      "grants.json registers payment tokens, which requires VAULT_ADMIN on the executing " +
        `multisig (${addresses.admin}), but it is assigned to ${holders.vaultAdmin}. ` +
        "Either leave VAULT_ADMIN with the multisig for the handover and move it afterwards, " +
        "or register the payment tokens separately from the batch.",
    );
  }

  // Part of the handover, not separate manual steps. A deployment missing them is INERT —
  // and would pass a role-only audit, because the roles are all correct.
  const market: SafeTransaction[] = [];
  // Separated UNCONDITIONALLY, not only when the addresses differ: folding them together is
  // wrong exactly when they do, and a split that depended on noticing would be no protection.
  const treasuryActions: SafeTransaction[] = [];
  for (const paymentToken of config.paymentTokens) {
    for (const [label, vault] of [
      ["DepositVault", addresses.depositVault],
      ["RedemptionVault", addresses.redemptionVault],
    ] as const) {
      market.push({
        to: vault,
        value: "0",
        data: encodeFunctionData({
          abi: ADD_PAYMENT_TOKEN_ABI,
          functionName: "addPaymentToken",
          args: [paymentToken.address, paymentToken.feeBps, paymentToken.allowanceWad],
        }),
        description: `addPaymentToken(${paymentToken.address}) -> ${label}`,
      });
    }

    treasuryActions.push({
      to: paymentToken.address,
      value: "0",
      data: encodeFunctionData({
        abi: ERC20_APPROVE_ABI,
        functionName: "approve",
        args: [addresses.redemptionVault, MAX_UINT256],
      }),
      description:
        `approve(RedemptionVault) on ${paymentToken.address} — MUST be sent by the ` +
        `tokensProvider (${addresses.treasury}); redemptions pull from it`,
    });
  }

  const refundGrantCalldata = encodeFunctionData({
    abi: GRANT_ROLE_ABI,
    functionName: "grantRole",
    args: [ROLE_IDS.REFUND_VAULT, addresses.redemptionVault],
  });

  const scheduled: SafeTransaction = {
    to: addresses.timelock,
    value: "0",
    data: encodeFunctionData({
      abi: TIMELOCK_SCHEDULE_ABI,
      functionName: "schedule",
      args: [
        addresses.accessRegistry,
        0n,
        refundGrantCalldata,
        EMPTY_BYTES32,
        EMPTY_BYTES32,
        config.timelockDelaySeconds,
      ],
    }),
    description:
      "SCHEDULE REFUND_VAULT -> RedemptionVault (critical; execute after the timelock delay)",
  };

  return { multisig: [...operational, ...market, scheduled], treasury: treasuryActions };
}

/** Calldata for executing the scheduled REFUND_VAULT grant once it has matured. */
export function refundGrantExecution(addresses: AddressBook): {
  target: Address;
  value: bigint;
  data: `0x${string}`;
  predecessor: `0x${string}`;
  salt: `0x${string}`;
} {
  return {
    target: addresses.accessRegistry,
    value: 0n,
    data: encodeFunctionData({
      abi: GRANT_ROLE_ABI,
      functionName: "grantRole",
      args: [ROLE_IDS.REFUND_VAULT, addresses.redemptionVault],
    }),
    predecessor: EMPTY_BYTES32,
    salt: EMPTY_BYTES32,
  };
}

function deploymentDir(networkName: string): string {
  return join(process.cwd(), "deployments", networkName);
}

/**
 * Persisted because `verify-deployment` previously read `REFERENCE_CONFIG` directly, so it
 * compared the chain against the same source the deployment was built from: it could not
 * detect "the config itself was wrong", and reported false failures on non-default holders.
 */
export interface DeploymentRecord {
  addresses: AddressBook;
  holders: OperationalHolders;
  config: PlatformConfig;
}

/** JSON has no bigint. Tagged round-trip rather than a lossy Number cast. */
function bigintReplacer(_key: string, value: unknown): unknown {
  return typeof value === "bigint" ? `${value.toString()}n` : value;
}

function bigintReviver(_key: string, value: unknown): unknown {
  return typeof value === "string" && /^-?\d+n$/.test(value) ? BigInt(value.slice(0, -1)) : value;
}

export function writeDeploymentRecord(record: DeploymentRecord): string {
  const path = join(deploymentDir(record.addresses.network), "deployment.json");
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(record, bigintReplacer, 2)}\n`);
  return path;
}

export function readDeploymentRecord(networkName: string): DeploymentRecord {
  const path = join(deploymentDir(networkName), "deployment.json");
  return JSON.parse(readFileSync(path, "utf8"), bigintReviver) as DeploymentRecord;
}

export function writeAddressBook(addresses: AddressBook): string {
  const path = join(deploymentDir(addresses.network), "addresses.json");
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(addresses, null, 2)}\n`);
  return path;
}

export function readAddressBook(networkName: string): AddressBook {
  const path = join(deploymentDir(networkName), "addresses.json");
  return JSON.parse(readFileSync(path, "utf8")) as AddressBook;
}

/** Writes the batch in Safe Transaction Builder format. */
export function writeGrantBatch(
  addresses: AddressBook,
  chainId: number,
  grants: SafeTransaction[],
  fileName = "grants.json",
  meta?: { name: string; description: string },
): string {
  const path = join(deploymentDir(addresses.network), fileName);
  mkdirSync(dirname(path), { recursive: true });

  const batch = {
    version: "1.0",
    chainId: String(chainId),
    meta: meta ?? {
      name: "RWA platform — role grants",
      description:
        "Execute as the client multisig. The final entry SCHEDULES a critical grant; " +
        "return after the timelock delay to execute it, then run verify-deployment, " +
        "then unpause.",
    },
    // The Safe Transaction Builder shows `description`, and one entry — the provider
    // approval — carries an instruction the signer cannot infer from calldata: it must be
    // sent BY the tokensProvider. Stripping it leaves a reviewer approving opaque blobs.
    transactions: grants.map(({ to, value, data, description }) => ({
      to,
      value,
      data,
      contractMethod: null,
      contractInputsValues: null,
      description,
    })),
  };

  writeFileSync(path, `${JSON.stringify(batch, null, 2)}\n`);
  return path;
}
