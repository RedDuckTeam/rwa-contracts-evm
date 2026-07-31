// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

/// @dev Read surface of the Chainalysis sanctions oracle. Consumed through a gas-capped
///      staticcall so a misbehaving oracle cannot brick the compliance layer.
interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}
