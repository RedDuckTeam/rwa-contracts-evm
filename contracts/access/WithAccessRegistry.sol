// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IAccessRegistry} from "../interfaces/IAccessRegistry.sol";
import {Roles} from "./Roles.sol";

/// @dev The registry address is set once and has no setter: repointing it would swap the
///      entire privilege model in one transaction, so it is reachable only by upgrade.
abstract contract WithAccessRegistry is Initializable {
    /// @custom:storage-location erc7201:rwa.storage.WithAccessRegistry
    struct WithAccessRegistryStorage {
        IAccessRegistry accessRegistry;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.WithAccessRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITH_ACCESS_REGISTRY_STORAGE_LOCATION =
        0x24a3d3016e65a23d82bb43265c033c0b5dfaaf4ca1a9383e6edefef3de348900;

    error MissingRole(bytes32 role, address account);

    error ZeroAccessRegistry();

    modifier onlyRegistryRole(bytes32 role) {
        _checkRegistryRole(role, msg.sender);
        _;
    }

    function accessRegistry() public view returns (IAccessRegistry) {
        return _withAccessRegistryStorage().accessRegistry;
    }

    /// @dev A fork sharing one registry across products MUST override the vault-bound roles
    ///      (MINTER, BURNER, REFUND_VAULT) per product, or product A's vault holds live
    ///      privileges over product B's token.
    function upgraderRole() public view virtual returns (bytes32) {
        return Roles.UPGRADER_ROLE;
    }

    function criticalConfigRole() public view virtual returns (bytes32) {
        return Roles.CRITICAL_CONFIG_ROLE;
    }

    function pauserRole() public view virtual returns (bytes32) {
        return Roles.PAUSER_ROLE;
    }

    function unpauserRole() public view virtual returns (bytes32) {
        return Roles.UNPAUSER_ROLE;
    }

    // solhint-disable-next-line func-name-mixedcase
    function __WithAccessRegistry_init(address registry) internal onlyInitializing {
        if (registry == address(0)) revert ZeroAccessRegistry();
        _withAccessRegistryStorage().accessRegistry = IAccessRegistry(registry);
    }

    function _checkRegistryRole(bytes32 role, address account) internal view {
        if (!_withAccessRegistryStorage().accessRegistry.hasRole(role, account)) {
            revert MissingRole(role, account);
        }
    }

    /// @dev Non-reverting, for view paths that must not revert.
    function _hasRegistryRole(bytes32 role, address account) internal view returns (bool) {
        return _withAccessRegistryStorage().accessRegistry.hasRole(role, account);
    }

    function _withAccessRegistryStorage() private pure returns (WithAccessRegistryStorage storage $) {
        assembly ("memory-safe") {
            $.slot := WITH_ACCESS_REGISTRY_STORAGE_LOCATION
        }
    }
}
