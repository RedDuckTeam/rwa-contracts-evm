// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {WithAccessRegistry} from "../access/WithAccessRegistry.sol";

/// @dev Per-operation switches rather than OpenZeppelin's single global flag: with one
///      switch, stopping deposits during an incident also stops redemptions.
///
///      Pausing and unpausing are split across two roles. PAUSER sits with a monitoring bot,
///      a hot key that can only make the system safer; UNPAUSER sits with the multisig. One
///      role holding both makes the breaker self-resettable by whoever took that key.
abstract contract OperationPausable is WithAccessRegistry {
    /// @custom:storage-location erc7201:rwa.storage.OperationPausable
    struct OperationPausableStorage {
        mapping(bytes32 opId => bool isPaused) paused;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.OperationPausable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OPERATION_PAUSABLE_STORAGE_LOCATION =
        0x5ca397301b49c09de586dd8684d9bc362f8b82bdb19fa3b8630d09a7a3a18e00;

    event OperationPaused(bytes32 indexed opId, address indexed account);

    event OperationUnpaused(bytes32 indexed opId, address indexed account);

    error OperationIsPaused(bytes32 opId);

    error PauseStateUnchanged(bytes32 opId);

    error UnsupportedOperation(bytes32 opId);

    modifier whenOperationNotPaused(bytes32 opId) {
        if (isOperationPaused(opId)) revert OperationIsPaused(opId);
        _;
    }

    function isOperationPaused(bytes32 opId) public view returns (bool) {
        return _operationPausableStorage().paused[opId];
    }

    function supportedOperations() public view virtual returns (bytes32[] memory);

    function pauseOperation(bytes32 opId) external onlyRegistryRole(pauserRole()) {
        _setOperationPaused(opId, true);
    }

    function unpauseOperation(bytes32 opId) external onlyRegistryRole(unpauserRole()) {
        _setOperationPaused(opId, false);
    }

    /// @dev Deployments start fully paused so a half-finished handover cannot move user funds.
    ///
    ///      Takes the flag rather than being called conditionally: the upgrade-safety
    ///      validator requires every parent initialiser to be invoked unconditionally, and a
    ///      guarded call reads to it as a missing one.
    // solhint-disable-next-line func-name-mixedcase
    function __OperationPausable_init(bool pauseAll) internal onlyInitializing {
        if (!pauseAll) return;

        bytes32[] memory ops = supportedOperations();
        OperationPausableStorage storage $ = _operationPausableStorage();
        for (uint256 i; i < ops.length; ++i) {
            $.paused[ops[i]] = true;
            emit OperationPaused(ops[i], msg.sender);
        }
    }

    function _setOperationPaused(bytes32 opId, bool shouldPause) private {
        // Unknown opIds are rejected rather than accepted as inert flags: an operator must not
        // believe they paused something during an incident when nothing was gated by that id.
        if (!_isSupportedOperation(opId)) revert UnsupportedOperation(opId);

        OperationPausableStorage storage $ = _operationPausableStorage();
        if ($.paused[opId] == shouldPause) revert PauseStateUnchanged(opId);
        $.paused[opId] = shouldPause;

        if (shouldPause) {
            emit OperationPaused(opId, msg.sender);
        } else {
            emit OperationUnpaused(opId, msg.sender);
        }
    }

    function _isSupportedOperation(bytes32 opId) private view returns (bool) {
        bytes32[] memory ops = supportedOperations();
        for (uint256 i; i < ops.length; ++i) {
            if (ops[i] == opId) return true;
        }
        return false;
    }

    function _operationPausableStorage() private pure returns (OperationPausableStorage storage $) {
        assembly ("memory-safe") {
            $.slot := OPERATION_PAUSABLE_STORAGE_LOCATION
        }
    }
}
