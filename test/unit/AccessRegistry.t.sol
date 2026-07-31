// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {AccessRegistry} from "../../contracts/access/AccessRegistry.sol";
import {IAccessRegistry} from "../../contracts/interfaces/IAccessRegistry.sol";
import {Roles} from "../../contracts/access/Roles.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract AccessRegistryTest is PlatformFixture {
    function setUp() public {
        _deployAccessLayer();
    }

    function test_InitialiseWiresAdminAndTimelock() public view {
        assertEq(registry.defaultAdmin(), admin);
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));

        // The timelock, and only the timelock, holds the critical roles that exist at
        // deployment time.
        assertTrue(registry.hasRole(Roles.TIMELOCK_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.CRITICAL_CONFIG_ROLE, address(timelock)));

        assertEq(registry.getRoleMemberCount(Roles.TIMELOCK_ADMIN_ROLE), 1);
        assertEq(registry.getRoleMemberCount(Roles.UPGRADER_ROLE), 1);
        assertEq(registry.getRoleMemberCount(Roles.CRITICAL_CONFIG_ROLE), 1);

        // Deliberately granted to nobody.
        assertEq(registry.getRoleMemberCount(Roles.ENFORCER_ROLE), 0);
        assertEq(registry.getRoleMemberCount(Roles.REFUND_VAULT_ROLE), 0);

        // The deployer must never end up with authority.
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_CriticalRolesAreAdministeredByTheTimelockRole() public view {
        assertEq(registry.getRoleAdmin(Roles.TIMELOCK_ADMIN_ROLE), Roles.TIMELOCK_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(Roles.UPGRADER_ROLE), Roles.TIMELOCK_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(Roles.CRITICAL_CONFIG_ROLE), Roles.TIMELOCK_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(Roles.REFUND_VAULT_ROLE), Roles.TIMELOCK_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(Roles.ENFORCER_ROLE), Roles.TIMELOCK_ADMIN_ROLE);
    }

    function test_OperationalRolesAreAdministeredByDefaultAdmin() public view {
        bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();
        assertEq(registry.getRoleAdmin(Roles.COMPLIANCE_ADMIN_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.GREENLIST_OPERATOR_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.BLACKLIST_OPERATOR_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.REQUEST_OPERATOR_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.VAULT_ADMIN_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.FEED_OPERATOR_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.FEED_ADMIN_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.PAUSER_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.UNPAUSER_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.MINTER_ROLE), defaultAdminRole);
        assertEq(registry.getRoleAdmin(Roles.BURNER_ROLE), defaultAdminRole);
    }

    function test_RevertWhen_InitialiseWithZeroAddress() public {
        AccessRegistry impl = new AccessRegistry();

        vm.expectRevert(AccessRegistry.ZeroAddress.selector);
        _proxy(address(impl), abi.encodeCall(AccessRegistry.initialize, (address(0), address(timelock))));

        vm.expectRevert(AccessRegistry.ZeroAddress.selector);
        _proxy(address(impl), abi.encodeCall(AccessRegistry.initialize, (admin, address(0))));
    }

    /// @dev An implementation that can still be initialised is a takeover vector: whoever
    ///      calls `initialize` on it can upgrade it out from under every proxy.
    function test_RevertWhen_ImplementationIsInitialisedDirectly() public {
        AccessRegistry impl = new AccessRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(admin, address(timelock));
    }

    function test_RevertWhen_ProxyIsInitialisedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(admin, address(timelock));
    }

    function test_DefaultAdminGrantsAndRevokesOperationalRoles() public {
        _grantOperational(Roles.PAUSER_ROLE, pauser);
        assertTrue(registry.hasRole(Roles.PAUSER_ROLE, pauser));
        assertEq(registry.getRoleMember(Roles.PAUSER_ROLE, 0), pauser);

        vm.prank(admin);
        registry.revokeRole(Roles.PAUSER_ROLE, pauser);
        assertFalse(registry.hasRole(Roles.PAUSER_ROLE, pauser));
        assertEq(registry.getRoleMemberCount(Roles.PAUSER_ROLE), 0);
    }

    function test_TimelockGrantsCriticalRole() public {
        _grantCriticalViaTimelock(Roles.REFUND_VAULT_ROLE, alice);

        assertTrue(registry.hasRole(Roles.REFUND_VAULT_ROLE, alice));
        assertEq(registry.getRoleMemberCount(Roles.REFUND_VAULT_ROLE), 1);
        assertEq(registry.getRoleMember(Roles.REFUND_VAULT_ROLE, 0), alice);
    }

    function test_OperationalRoleCanBeRenounced() public {
        _grantOperational(Roles.PAUSER_ROLE, pauser);

        vm.prank(pauser);
        registry.renounceRole(Roles.PAUSER_ROLE, pauser);

        assertFalse(registry.hasRole(Roles.PAUSER_ROLE, pauser));
    }

    /// @dev The core claim of the trust model: DEFAULT_ADMIN_ROLE — the position an attacker
    ///      reaches by compromising the multisig — buys no ability to hand out critical powers.
    function test_RevertWhen_DefaultAdminGrantsCriticalRole() public {
        bytes32[5] memory critical = [
            Roles.TIMELOCK_ADMIN_ROLE,
            Roles.UPGRADER_ROLE,
            Roles.CRITICAL_CONFIG_ROLE,
            Roles.REFUND_VAULT_ROLE,
            Roles.ENFORCER_ROLE
        ];

        for (uint256 i; i < critical.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    admin,
                    Roles.TIMELOCK_ADMIN_ROLE
                )
            );
            registry.grantRole(critical[i], alice);
        }
    }

    function test_RevertWhen_NonAdminGrantsOperationalRole() public {
        // Read the role id before pranking: an external call placed after `vm.prank` consumes
        // it, and the assertion would silently test the wrong sender.
        bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                defaultAdminRole
            )
        );
        registry.grantRole(Roles.PAUSER_ROLE, alice);
    }

    /// @dev Renouncing needs no approval, so it is the one unilateral move a critical role
    ///      holder has. Dropping TIMELOCK_ADMIN_ROLE would make upgrades permanently
    ///      unreachable.
    function test_RevertWhen_CriticalRoleIsRenounced() public {
        _grantCriticalViaTimelock(Roles.REFUND_VAULT_ROLE, alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AccessRegistry.CriticalRoleNotRenounceable.selector, Roles.REFUND_VAULT_ROLE)
        );
        registry.renounceRole(Roles.REFUND_VAULT_ROLE, alice);

        assertTrue(registry.hasRole(Roles.REFUND_VAULT_ROLE, alice));
    }

    function test_RevertWhen_TimelockRenouncesAnyCriticalRole() public {
        bytes32[3] memory held = [Roles.TIMELOCK_ADMIN_ROLE, Roles.UPGRADER_ROLE, Roles.CRITICAL_CONFIG_ROLE];

        for (uint256 i; i < held.length; ++i) {
            vm.prank(address(timelock));
            vm.expectRevert(
                abi.encodeWithSelector(AccessRegistry.CriticalRoleNotRenounceable.selector, held[i])
            );
            registry.renounceRole(held[i], address(timelock));

            assertTrue(registry.hasRole(held[i], address(timelock)));
        }
    }

    /// @dev DEFAULT_ADMIN_ROLE must move only through the delayed two-step transfer. Proven
    ///      here because the diamond override could have dropped the guard by naming a single
    ///      parent instead of dispatching through `super`.
    function test_RevertWhen_DefaultAdminRoleIsGrantedDirectly() public {
        bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        registry.grantRole(defaultAdminRole, alice);

        vm.prank(admin);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        registry.revokeRole(defaultAdminRole, admin);
    }

    /// @dev If one were ever added, a compromised admin could re-point a critical role at
    ///      itself and grant it instantly, routing around the timelock.
    function test_NoPublicSetRoleAdminEntryPoint() public {
        bytes memory payload = abi.encodeWithSignature(
            "setRoleAdmin(bytes32,bytes32)",
            Roles.UPGRADER_ROLE,
            registry.DEFAULT_ADMIN_ROLE()
        );

        vm.prank(admin);
        (bool ok, ) = address(registry).call(payload);
        assertFalse(ok, "registry must not expose setRoleAdmin");

        assertEq(registry.getRoleAdmin(Roles.UPGRADER_ROLE), Roles.TIMELOCK_ADMIN_ROLE);
    }

    /// @dev Not even the timelock: the hierarchy is written once, in a spent `initialize`.
    function test_TimelockCannotRepointRoleHierarchy() public {
        bytes memory payload = abi.encodeWithSignature(
            "setRoleAdmin(bytes32,bytes32)",
            Roles.UPGRADER_ROLE,
            registry.DEFAULT_ADMIN_ROLE()
        );

        vm.prank(address(timelock));
        (bool ok, ) = address(registry).call(payload);
        assertFalse(ok);
        assertEq(registry.getRoleAdmin(Roles.UPGRADER_ROLE), Roles.TIMELOCK_ADMIN_ROLE);
    }

    function test_AdminTransferRequiresTwoStepsAndTheFullDelay() public {
        assertEq(registry.defaultAdminDelay(), 48 hours);

        vm.prank(admin);
        registry.beginDefaultAdminTransfer(bob);

        (address pending, uint48 schedule) = registry.pendingDefaultAdmin();
        assertEq(pending, bob);
        assertEq(schedule, uint48(block.timestamp + 48 hours));

        // OZ requires the schedule to be strictly in the past, so accepting at the scheduled
        // instant must still fail.
        vm.warp(schedule);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector,
                schedule
            )
        );
        registry.acceptDefaultAdminTransfer();
        assertEq(registry.defaultAdmin(), admin);

        vm.warp(schedule + 1);
        vm.prank(bob);
        registry.acceptDefaultAdminTransfer();

        assertEq(registry.defaultAdmin(), bob);
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_AdminTransferCanBeCancelled() public {
        vm.prank(admin);
        registry.beginDefaultAdminTransfer(bob);

        vm.prank(admin);
        registry.cancelDefaultAdminTransfer();

        (address pending, uint48 schedule) = registry.pendingDefaultAdmin();
        assertEq(pending, address(0));
        assertEq(schedule, 0);

        // With no pending admin the caller no longer matches and is rejected as invalid; the
        // delay check is never reached.
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector,
                bob
            )
        );
        registry.acceptDefaultAdminTransfer();

        assertEq(registry.defaultAdmin(), admin);
    }

    function test_RevertWhen_WrongAccountAcceptsAdminTransfer() public {
        vm.prank(admin);
        registry.beginDefaultAdminTransfer(bob);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector,
                alice
            )
        );
        registry.acceptDefaultAdminTransfer();

        assertEq(registry.defaultAdmin(), admin);
    }

    function test_IsCriticalRoleClassifiesEveryRole() public view {
        assertTrue(registry.isCriticalRole(Roles.TIMELOCK_ADMIN_ROLE));
        assertTrue(registry.isCriticalRole(Roles.UPGRADER_ROLE));
        assertTrue(registry.isCriticalRole(Roles.CRITICAL_CONFIG_ROLE));
        assertTrue(registry.isCriticalRole(Roles.REFUND_VAULT_ROLE));
        assertTrue(registry.isCriticalRole(Roles.ENFORCER_ROLE));

        assertFalse(registry.isCriticalRole(Roles.PAUSER_ROLE));
        assertFalse(registry.isCriticalRole(Roles.UNPAUSER_ROLE));
        assertFalse(registry.isCriticalRole(Roles.MINTER_ROLE));
        assertFalse(registry.isCriticalRole(Roles.BURNER_ROLE));
        assertFalse(registry.isCriticalRole(Roles.VAULT_ADMIN_ROLE));
        assertFalse(registry.isCriticalRole(registry.DEFAULT_ADMIN_ROLE()));
    }

    function testFuzz_UnknownRolesAreNotCritical(bytes32 role) public view {
        vm.assume(
            role != Roles.TIMELOCK_ADMIN_ROLE &&
                role != Roles.UPGRADER_ROLE &&
                role != Roles.CRITICAL_CONFIG_ROLE &&
                role != Roles.REFUND_VAULT_ROLE &&
                role != Roles.ENFORCER_ROLE
        );
        assertFalse(registry.isCriticalRole(role));
    }

    function test_SupportsExpectedInterfaces() public view {
        assertTrue(registry.supportsInterface(type(IAccessRegistry).interfaceId));
        assertTrue(registry.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(registry.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId));
        assertFalse(registry.supportsInterface(0xdeadbeef));
    }

    function test_GetRoleMembersEnumeratesEveryHolder() public {
        _grantOperational(Roles.PAUSER_ROLE, pauser);
        _grantOperational(Roles.PAUSER_ROLE, alice);

        address[] memory members = registry.getRoleMembers(Roles.PAUSER_ROLE);
        assertEq(members.length, 2);
        assertEq(members[0], pauser);
        assertEq(members[1], alice);
    }

    /// @dev The mint/burn boundary is an OPERATIONAL commitment: MINTER and BURNER are
    ///      administered by DEFAULT_ADMIN, so the multisig can hand either vault the other's
    ///      power immediately. Worth pinning, because the separation is load-bearing and
    ///      nothing in the contracts enforces it — which is why `verify-deployment` asserts
    ///      exact membership of both roles rather than assuming it holds.
    function test_MintAndBurnBoundaryIsOperationalNotEnforced() public {
        _grantOperational(Roles.MINTER_ROLE, alice);

        vm.prank(admin);
        registry.grantRole(Roles.BURNER_ROLE, alice);

        assertTrue(
            registry.hasRole(Roles.BURNER_ROLE, alice),
            "the registry refused: the boundary is contract-enforced after all, so the "
            "trust model and the deployment audit both need updating"
        );

        // Nothing timelocked stood in the way, which is the point being recorded.
        assertEq(registry.getRoleAdmin(Roles.BURNER_ROLE), registry.DEFAULT_ADMIN_ROLE());
    }

    function test_RevertWhen_NonUpgraderUpgradesRegistry() public {
        AccessRegistry nextImpl = new AccessRegistry();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                admin,
                Roles.UPGRADER_ROLE
            )
        );
        registry.upgradeToAndCall(address(nextImpl), "");
    }

    function test_TimelockUpgradesRegistry() public {
        AccessRegistry nextImpl = new AccessRegistry();

        _executeViaTimelock(
            address(registry),
            abi.encodeCall(registry.upgradeToAndCall, (address(nextImpl), ""))
        );

        // State survives, which is what makes the upgrade path safe to use at all.
        assertEq(registry.defaultAdmin(), admin);
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, address(timelock)));
    }
}
