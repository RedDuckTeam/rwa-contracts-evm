// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IERC7943 - uRWA, fungible variant
/// @notice Transcribed verbatim from ERC-7943 (Final). Do not tidy these signatures: the
///         interface id is derived from them.
/// @dev Normative rules quoted from the EIP:
///      * canSend / canReceive / canTransfer - "MUST NOT revert. MUST NOT change the storage
///        of the contract."
///      * canTransfer - "MUST validate that the amount being transferred doesn't exceed the
///        unfrozen amount."
///      * forcedTransfer - "MAY bypass the canTransfer checks. If this happens, and the
///        transfer involves tokens that are currently counted as frozen, it MUST unfreeze the
///        assets first and emit a Frozen event BEFORE the underlying base token transfer
///        event." The ordering is normative.
///      * setFrozenTokens - "MUST emit the Frozen event. MUST be restricted in access. MUST
///        allow freezing more assets than those held."
interface IERC7943 is IERC165 {
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);

    event Frozen(address indexed account, uint256 amount);

    error ERC7943CannotSend(address account);
    error ERC7943CannotReceive(address account);
    error ERC7943CannotTransfer(address from, address to, uint256 amount);
    error ERC7943InsufficientUnfrozenBalance(address account, uint256 amount, uint256 unfrozen);

    function forcedTransfer(address from, address to, uint256 amount) external returns (bool result);

    function setFrozenTokens(address account, uint256 amount) external returns (bool result);

    function canSend(address account) external view returns (bool allowed);

    function canReceive(address account) external view returns (bool allowed);

    function getFrozenTokens(address account) external view returns (uint256 amount);

    function canTransfer(address from, address to, uint256 amount) external view returns (bool allowed);
}
