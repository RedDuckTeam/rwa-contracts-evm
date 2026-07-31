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
  {
    type: "function",
    name: "hashOperation",
    inputs: [
      { name: "target", type: "address" },
      { name: "value", type: "uint256" },
      { name: "data", type: "bytes" },
      { name: "predecessor", type: "bytes32" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [{ type: "bytes32" }],
    stateMutability: "pure",
  },
  {
    type: "function",
    name: "getTimestamp",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
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
  // `getWalletClient(address)` and not `getWalletClients({ account })`: the latter takes a viem
  // client CONFIG, not a filter, so it returns one client per provider account with the same
  // `account` stamped on each — indistinguishable from a filter on a one-account chain, and
  // silently the wrong client on a chain with several.
  const wallet = await connection.viem.getWalletClient(admin);
  const publicClient = await connection.viem.getPublicClient();

  for (const grant of grants) {
    const hash = await wallet.sendTransaction({ to: grant.to, data: grant.data, value: 0n });
    await publicClient.waitForTransactionReceipt({ hash });
    log(`  executed: ${grant.description}`);
  }
}

/**
 * The same batch, replayed on a chain where SOME of it may already have landed — the shape a
 * resumed handover is always in, whether it was interrupted or the multisig executed the first
 * half through the Safe UI.
 *
 * Entries are simulated first and skipped when the simulation reverts. That deliberately does
 * NOT distinguish "already applied" from "genuinely broken": `grantRole` is idempotent and
 * would not revert either way, while `addPaymentToken` and `schedule` revert on both. Deciding
 * between them here would mean re-deriving each call's intent from its calldata. The decision
 * belongs to `verifyDeployment`, which asserts the resulting STATE — exact role membership,
 * registered tokens, the provider allowance — and fails the handover if anything skipped here
 * actually mattered.
 */
export async function replayGrantsResumable(
  connection: AnyNetworkConnection,
  signer: Address,
  grants: SafeTransaction[],
  log: (message: string) => void = () => {},
): Promise<{ sent: number; skipped: number }> {
  const wallet = await connection.viem.getWalletClient(signer);
  const publicClient = await connection.viem.getPublicClient();

  let sent = 0;
  let skipped = 0;
  for (const grant of grants) {
    try {
      await publicClient.call({ account: signer, to: grant.to, data: grant.data });
    } catch (error) {
      log(`  skipped:  ${grant.description}  (${describeRevert(error)})`);
      skipped += 1;
      continue;
    }

    const hash = await wallet.sendTransaction({ to: grant.to, data: grant.data, value: 0n });
    await publicClient.waitForTransactionReceipt({ hash });
    log(`  executed: ${grant.description}`);
    sent += 1;
  }

  return { sent, skipped };
}

/**
 * viem's top-level message for a reverting `eth_call` is "An unknown RPC error occurred",
 * which tells an operator nothing about which entry was skipped or why. The useful parts are
 * further down: the node's own text in `details`, and the raw revert payload on some link of
 * the cause chain. The four-byte selector alone identifies the custom error — a reader can
 * match it against the contract — where the generic message identifies nothing.
 */
function describeRevert(error: unknown): string {
  const parts: string[] = [];

  const top = error as { details?: unknown; shortMessage?: unknown } | null;
  if (typeof top?.details === "string" && top.details.length > 0) parts.push(top.details);
  else if (typeof top?.shortMessage === "string") parts.push(top.shortMessage);

  for (let cause: unknown = error, depth = 0; cause !== undefined && depth < 10; depth += 1) {
    const node = cause as { data?: unknown; cause?: unknown };
    if (typeof node.data === "string" && node.data.startsWith("0x") && node.data.length >= 10) {
      parts.push(`revert selector ${node.data.slice(0, 10)}`);
      break;
    }
    cause = node.cause;
  }

  if (parts.length === 0) {
    const raw = error instanceof Error ? error.message : String(error);
    parts.push(raw.split("\n")[0] ?? raw);
  }
  return parts.join("; ");
}

/** Live pause state of every switch the handover touches, in the order it lifts them. */
export async function readPausePosture(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
): Promise<{ label: string; paused: boolean }[]> {
  const publicClient = await connection.viem.getPublicClient();

  const states: { label: string; paused: boolean }[] = [];
  for (const [label, target, opId] of pauseTargets(addresses)) {
    states.push({
      label,
      paused: (await publicClient.readContract({
        address: target,
        abi: PAUSE_STATE_ABI,
        functionName: "isOperationPaused",
        args: [opId],
      })) as boolean,
    });
  }
  return states;
}

/**
 * NAV posting comes first and the user-facing operations after, because every priced path
 * reverts on a stale feed: opening the product before a price can be posted would open one
 * whose every operation fails.
 */
function pauseTargets(addresses: AddressBook): [string, Address, `0x${string}`][] {
  return [
    ["Aggregator/ORACLE_UPDATE", addresses.aggregator, OP_IDS.ORACLE_UPDATE],
    ["Token/TRANSFER", addresses.token, OP_IDS.TRANSFER],
    ["DepositVault/DEPOSIT_INSTANT", addresses.depositVault, OP_IDS.DEPOSIT_INSTANT],
    ["DepositVault/DEPOSIT_REQUEST", addresses.depositVault, OP_IDS.DEPOSIT_REQUEST],
    ["RedemptionVault/REDEEM_INSTANT", addresses.redemptionVault, OP_IDS.REDEEM_INSTANT],
    ["RedemptionVault/REDEEM_REQUEST", addresses.redemptionVault, OP_IDS.REDEEM_REQUEST],
  ];
}

export type RefundGrantState = "unscheduled" | "pending" | "ready" | "done";

/**
 * Where the one critical grant has got to. `TimelockController` encodes all four states in a
 * single timestamp: 0 unscheduled, 1 done, anything else the instant it becomes executable.
 */
export async function refundGrantStatus(
  connection: AnyNetworkConnection,
  addresses: AddressBook,
): Promise<{ state: RefundGrantState; readyAt: bigint }> {
  const publicClient = await connection.viem.getPublicClient();
  const call = refundGrantExecution(addresses);

  const id = (await publicClient.readContract({
    address: addresses.timelock,
    abi: TIMELOCK_EXECUTE_ABI,
    functionName: "hashOperation",
    args: [call.target, call.value, call.data, call.predecessor, call.salt],
  })) as `0x${string}`;

  const timestamp = (await publicClient.readContract({
    address: addresses.timelock,
    abi: TIMELOCK_EXECUTE_ABI,
    functionName: "getTimestamp",
    args: [id],
  })) as bigint;

  if (timestamp === 0n) return { state: "unscheduled", readyAt: 0n };
  if (timestamp === 1n) return { state: "done", readyAt: 0n };

  const block = await publicClient.getBlock();
  return { state: block.timestamp >= timestamp ? "ready" : "pending", readyAt: timestamp };
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
  const wallet = await connection.viem.getWalletClient(unpauser);
  const publicClient = await connection.viem.getPublicClient();

  for (const [label, target, opId] of pauseTargets(addresses)) {
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
