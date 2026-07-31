/**
 * Prints the ERC-7201 storage slot for each namespace passed on the command line. The slot
 * is a literal constant in the contract, so this is how it is produced and re-checked.
 *
 *   pnpm exec tsx scripts/erc7201.ts rwa.storage.AccessRegistry
 *   node --experimental-strip-types scripts/erc7201.ts rwa.storage.AccessRegistry
 */
import { encodeAbiParameters, keccak256, toHex } from "viem";

/** keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff)) */
export function erc7201Slot(namespace: string): `0x${string}` {
  const inner = BigInt(keccak256(toHex(namespace))) - 1n;
  const outer = BigInt(keccak256(encodeAbiParameters([{ type: "uint256" }], [inner])));
  const masked = outer & ~0xffn;
  return `0x${masked.toString(16).padStart(64, "0")}`;
}

const namespaces = process.argv.slice(2);

if (namespaces.length === 0) {
  console.error("usage: erc7201.ts <namespace> [namespace...]");
  process.exit(1);
}

for (const namespace of namespaces) {
  console.log(`${namespace}\n  ${erc7201Slot(namespace)}`);
}
