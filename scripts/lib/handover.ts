/**
 * Replaying the grant batch and lifting the fail-closed start. The integration test drives
 * these functions, so the tested path and the documented path are the same one: in production
 * the multisig executes `grants.json` through the Safe UI, here the same bytes are replayed
 * from an impersonated admin.
 */
import type { ChainType, NetworkConnection } from "hardhat/types/network";
import type { Address } from "viem";

import {
  OP_IDS,
  ROLE_IDS,
  refundGrantExecution,
  type AddressBook,
  type SafeTransaction,
} from "./deployment.js";

/**
 * `NetworkConnection` is invariant in its type parameter, so one created as
 * `NetworkConnection<"l1">` is not assignable to the default `<"generic">`. These helpers
 * care about none of that.
 */
type AnyNetworkConnection = NetworkConnection<ChainType | string>;

const TIMELOCK_EXECUTE_ABI = [
  {
    type: "function",
    name: "execute",
    inputs: [
      { name: "target", type: "address" },
      { name: "value", type: "uint256" },
      { name: "payload", type: "bytes" },
      { name: "predecessor", type: "bytes32" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
] as const;

const UNPAUSE_ABI = [
  {
    type: "function",
    name: "unpauseOperation",
    inputs: [{ name: "opId", type: "bytes32" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

const PAUSE_STATE_ABI = [
  {
    type: "function",
    name: "isOperationPaused",
    inputs: [{ name: "opId", type: "bytes32" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const;

const REGISTRY_HAS_ROLE_ABI = [
  {
    type: "function",
    name: "hasRole",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "account", type: "address" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const;

/**
 * Replays the ENCODED CALLDATA rather than re-deriving the calls, which is what makes this a
 * test of `grants.json` itself and not of a parallel implementation that agrees with it today.
 */
export async function replayGrants(
  connection: AnyNetworkConnection,
  admin: Address,
  grants: SafeTransaction[],
  log: (message: string) => void = () => {},
): Promise<void> {
  const [wallet] = await connection.viem.getWalletClients({ account: admin });
  if (wallet === undefined) throw new Error(`no wallet client for ${admin}`);
  const publicClient = await connection.viem.getPublicClient();

  for (const grant of grants) {
    const hash = await wallet.sendTransaction({ to: grant.to, data: grant.data, value: 0n });
    await publicClient.waitForTransactionReceipt({ hash });
    log(`  executed: ${grant.description}`);
  }
}

/**
 * Executes the REFUND_VAULT grant the batch could only schedule. The caller must have
 * advanced past the delay; the timelock has an open executor, so this needs no privileged
 * account.
 */
export async function executeScheduledRefundGrant(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
): Promise<void> {
  const [wallet] = await connection.viem.getWalletClients();
  if (wallet === undefined) throw new Error("no wallet client available");
  const publicClient = await connection.viem.getPublicClient();

  const call = refundGrantExecution(addresses);
  const hash = await wallet.writeContract({
    address: addresses.timelock,
    abi: TIMELOCK_EXECUTE_ABI,
    functionName: "execute",
    args: [call.target, call.value, call.data, call.predecessor, call.salt],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

/** Whether the RedemptionVault has actually received its critical role. */
export async function refundRoleIsGranted(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
): Promise<boolean> {
  const publicClient = await connection.viem.getPublicClient();
  return (await publicClient.readContract({
    address: addresses.accessRegistry,
    abi: REGISTRY_HAS_ROLE_ABI,
    functionName: "hasRole",
    args: [ROLE_IDS.REFUND_VAULT, addresses.redemptionVault],
  })) as boolean;
}

/**
 * Lifts the fail-closed start, ONLY after verification has passed. Ordering matters: NAV
 * posting is unpaused and a price posted before user-facing operations open, because every
 * priced path reverts on a stale feed and the price written at aggregator initialisation is
 * already old by the time a real handover completes.
 */
export async function unpauseAll(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
  unpauser: Address,
  log: (message: string) => void = () => {},
): Promise<void> {
  const [wallet] = await connection.viem.getWalletClients({ account: unpauser });
  if (wallet === undefined) throw new Error(`no wallet client for ${unpauser}`);
  const publicClient = await connection.viem.getPublicClient();

  const targets: [string, Address, `0x${string}`][] = [
    ["Aggregator/ORACLE_UPDATE", addresses.aggregator, OP_IDS.ORACLE_UPDATE],
    ["Token/TRANSFER", addresses.token, OP_IDS.TRANSFER],
    ["DepositVault/DEPOSIT_INSTANT", addresses.depositVault, OP_IDS.DEPOSIT_INSTANT],
    ["DepositVault/DEPOSIT_REQUEST", addresses.depositVault, OP_IDS.DEPOSIT_REQUEST],
    ["RedemptionVault/REDEEM_INSTANT", addresses.redemptionVault, OP_IDS.REDEEM_INSTANT],
    ["RedemptionVault/REDEEM_REQUEST", addresses.redemptionVault, OP_IDS.REDEEM_REQUEST],
  ];

  for (const [label, target, opId] of targets) {
    // Idempotent by design: a real handover may have already lifted one switch, and the
    // contract reverts on a no-op unpause, so resuming must not be a dead end.
    const paused = (await publicClient.readContract({
      address: target,
      abi: PAUSE_STATE_ABI,
      functionName: "isOperationPaused",
      args: [opId],
    })) as boolean;

    if (!paused) {
      log(`  already live: ${label}`);
      continue;
    }

    const hash = await wallet.writeContract({
      address: target,
      abi: UNPAUSE_ABI,
      functionName: "unpauseOperation",
      args: [opId],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    log(`  unpaused: ${label}`);
  }
}
