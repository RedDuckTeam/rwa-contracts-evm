// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {IAccessRegistry} from "../interfaces/IAccessRegistry.sol";
import {Roles} from "./Roles.sol";

/// @dev Blacklist and greenlist status are deliberately not roles: AccessControl roles are
///      always self-renounceable, and a blacklisted account must not be able to clear its
///      own status. They live in {ComplianceRegistry} as plain mappings.
contract AccessRegistry is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    IAccessRegistry
{
    /// @dev Matched to the TimelockController's minDelay: if they differed, the shorter one
    ///      would set the real reaction window.
    uint48 public constant DEFAULT_ADMIN_TRANSFER_DELAY = 48 hours;

    error CriticalRoleNotRenounceable(bytes32 role);

    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Fixes the role hierarchy for the lifetime of the deployment. There is no public
    ///      `setRoleAdmin`; a DEFAULT_ADMIN that could re-point a critical role's admin at
    ///      itself would route around the timelock entirely.
    function initialize(address initialDefaultAdmin, address timelock) external initializer {
        if (initialDefaultAdmin == address(0) || timelock == address(0)) revert ZeroAddress();

        __AccessControlDefaultAdminRules_init(DEFAULT_ADMIN_TRANSFER_DELAY, initialDefaultAdmin);
        __AccessControlEnumerable_init();

        _setRoleAdmin(Roles.TIMELOCK_ADMIN_ROLE, Roles.TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(Roles.UPGRADER_ROLE, Roles.TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(Roles.CRITICAL_CONFIG_ROLE, Roles.TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(Roles.REFUND_VAULT_ROLE, Roles.TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(Roles.ENFORCER_ROLE, Roles.TIMELOCK_ADMIN_ROLE);

        // REFUND_VAULT_ROLE is granted later through the timelock, once the RedemptionVault
        // address exists; ENFORCER_ROLE is granted to nobody.
        _grantRole(Roles.TIMELOCK_ADMIN_ROLE, timelock);
        _grantRole(Roles.UPGRADER_ROLE, timelock);
        _grantRole(Roles.CRITICAL_CONFIG_ROLE, timelock);
    }

    /// @inheritdoc IAccessRegistry
    function isCriticalRole(bytes32 role) public pure returns (bool) {
        return
            role == Roles.TIMELOCK_ADMIN_ROLE ||
            role == Roles.UPGRADER_ROLE ||
            role == Roles.CRITICAL_CONFIG_ROLE ||
            role == Roles.REFUND_VAULT_ROLE ||
            role == Roles.ENFORCER_ROLE;
    }

    /// @dev Renouncing needs no admin approval, so it is the one unilateral path a role
    ///      holder has. Renouncing TIMELOCK_ADMIN_ROLE would permanently brick upgrades.
    ///      Revoking a critical role still works, through the timelock.
    function renounceRole(
        bytes32 role,
        address account
    ) public override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IAccessControl) {
        if (isCriticalRole(role)) revert CriticalRoleNotRenounceable(role);
        super.renounceRole(role, account);
    }

    /// @dev The diamond overrides below exist only to satisfy Solidity's explicit-resolution
    ///      rule. Every one must dispatch through `super` so the full C3 chain runs: naming a
    ///      single parent instead silently drops either the DefaultAdminRules guard or the
    ///      Enumerable member set.
    function grantRole(
        bytes32 role,
        address account
    ) public override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IAccessControl) {
        super.grantRole(role, account);
    }

    function revokeRole(
        bytes32 role,
        address account
    ) public override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IAccessControl) {
        super.revokeRole(role, account);
    }

    function _setRoleAdmin(
        bytes32 role,
        bytes32 adminRole
    ) internal override(AccessControlUpgradeable, AccessControlDefaultAdminRulesUpgradeable) {
        super._setRoleAdmin(role, adminRole);
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IAccessRegistry).interfaceId || super.supportsInterface(interfaceId);
    }

    function _grantRole(
        bytes32 role,
        address account
    )
        internal
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super._grantRole(role, account);
    }

    function _revokeRole(
        bytes32 role,
        address account
    )
        internal
        override(AccessControlDefaultAdminRulesUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super._revokeRole(role, account);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
