// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Roles} from "../../contracts/access/Roles.sol";
import {WithAccessRegistry} from "../../contracts/access/WithAccessRegistry.sol";
import {OperationPausable} from "../../contracts/pause/OperationPausable.sol";
import {OperationPausableTester} from "../../contracts/testers/OperationPausableTester.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract OperationPausableTest is PlatformFixture {
    OperationPausableTester internal pausable;

    function setUp() public {
        _deployAccessLayer();
        _grantOperational(Roles.PAUSER_ROLE, pauser);
        _grantOperational(Roles.UNPAUSER_ROLE, unpauser);

        pausable = _deployTester(false);
    }

    function _deployTester(bool startPaused) internal returns (OperationPausableTester) {
        OperationPausableTester impl = new OperationPausableTester();
        return
            OperationPausableTester(
                _proxy(
                    address(impl),
                    abi.encodeCall(OperationPausableTester.initialize, (address(registry), startPaused))
                )
            );
    }

    /// @dev A deployment must not move user funds between the moment it lands and the moment
    ///      its role wiring has been verified.
    function test_InitialiseWithAllOperationsPaused() public {
        OperationPausableTester fresh = _deployTester(true);

        assertTrue(fresh.isOperationPaused(Roles.OP_DEPOSIT_INSTANT));
        assertTrue(fresh.isOperationPaused(Roles.OP_REDEEM_INSTANT));

        vm.expectRevert(
            abi.encodeWithSelector(OperationPausable.OperationIsPaused.selector, Roles.OP_DEPOSIT_INSTANT)
        );
        fresh.doDeposit();
    }

    function test_InitialiseUnpausedForLocalDevelopment() public view {
        assertFalse(pausable.isOperationPaused(Roles.OP_DEPOSIT_INSTANT));
        assertFalse(pausable.isOperationPaused(Roles.OP_REDEEM_INSTANT));
    }

    /// @dev Why this exists instead of a single global flag: stopping deposits during an
    ///      incident must not also strand everyone trying to redeem.
    function test_PausingOneOperationLeavesTheOtherLive() public {
        vm.prank(pauser);
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.expectRevert(
            abi.encodeWithSelector(OperationPausable.OperationIsPaused.selector, Roles.OP_DEPOSIT_INSTANT)
        );
        pausable.doDeposit();

        pausable.doRedeem();
        assertEq(pausable.redeemCount(), 1);
    }

    function test_UnpauseRestoresTheOperation() public {
        vm.prank(pauser);
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.prank(unpauser);
        pausable.unpauseOperation(Roles.OP_DEPOSIT_INSTANT);

        pausable.doDeposit();
        assertEq(pausable.depositCount(), 1);
    }

    function test_EmitsPauseAndUnpauseEvents() public {
        vm.expectEmit(true, true, false, false, address(pausable));
        emit OperationPausable.OperationPaused(Roles.OP_REDEEM_INSTANT, pauser);
        vm.prank(pauser);
        pausable.pauseOperation(Roles.OP_REDEEM_INSTANT);

        vm.expectEmit(true, true, false, false, address(pausable));
        emit OperationPausable.OperationUnpaused(Roles.OP_REDEEM_INSTANT, unpauser);
        vm.prank(unpauser);
        pausable.unpauseOperation(Roles.OP_REDEEM_INSTANT);
    }

    /// @dev The asymmetry is the point of splitting the roles: whoever holds the hot monitoring
    ///      key can stop the system but not restart it, so taking that key cannot quietly undo
    ///      the circuit breaker.
    function test_RevertWhen_PauserTriesToUnpause() public {
        vm.prank(pauser);
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UNPAUSER_ROLE, pauser)
        );
        pausable.unpauseOperation(Roles.OP_DEPOSIT_INSTANT);

        assertTrue(pausable.isOperationPaused(Roles.OP_DEPOSIT_INSTANT));
    }

    function test_RevertWhen_UnpauserTriesToPause() public {
        vm.prank(unpauser);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.PAUSER_ROLE, unpauser)
        );
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);
    }

    function test_RevertWhen_StrangerPausesOrUnpauses() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.PAUSER_ROLE, alice)
        );
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UNPAUSER_ROLE, alice)
        );
        pausable.unpauseOperation(Roles.OP_DEPOSIT_INSTANT);
    }

    /// @dev Immediately: the operational tier is deliberately not timelocked.
    function test_RevokedPauserLosesTheAbilityAtOnce() public {
        vm.prank(admin);
        registry.revokeRole(Roles.PAUSER_ROLE, pauser);

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.PAUSER_ROLE, pauser)
        );
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);
    }

    /// @dev Accepting an unknown opId would let an operator believe they had stopped something
    ///      mid-incident while nothing was gated by that id.
    function test_RevertWhen_OperationIdIsNotGoverned() public {
        bytes32 stranger = keccak256("rwa.op.NOT_A_REAL_OPERATION");

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OperationPausable.UnsupportedOperation.selector, stranger));
        pausable.pauseOperation(stranger);

        vm.prank(unpauser);
        vm.expectRevert(abi.encodeWithSelector(OperationPausable.UnsupportedOperation.selector, stranger));
        pausable.unpauseOperation(stranger);
    }

    /// @dev A no-op pause would emit an event saying nothing changed — the one signal an
    ///      incident responder must not receive.
    function test_RevertWhen_PauseStateWouldNotChange() public {
        vm.prank(pauser);
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(OperationPausable.PauseStateUnchanged.selector, Roles.OP_DEPOSIT_INSTANT)
        );
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.prank(unpauser);
        pausable.unpauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.prank(unpauser);
        vm.expectRevert(
            abi.encodeWithSelector(OperationPausable.PauseStateUnchanged.selector, Roles.OP_DEPOSIT_INSTANT)
        );
        pausable.unpauseOperation(Roles.OP_DEPOSIT_INSTANT);
    }

    function test_SupportedOperationsListsEveryGatedFlow() public view {
        bytes32[] memory ops = pausable.supportedOperations();
        assertEq(ops.length, 2);
        assertEq(ops[0], Roles.OP_DEPOSIT_INSTANT);
        assertEq(ops[1], Roles.OP_REDEEM_INSTANT);
    }

    function testFuzz_UnknownOperationsAreAlwaysRejected(bytes32 opId) public {
        vm.assume(opId != Roles.OP_DEPOSIT_INSTANT && opId != Roles.OP_REDEEM_INSTANT);

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(OperationPausable.UnsupportedOperation.selector, opId));
        pausable.pauseOperation(opId);
    }

    function test_ExposesTheRegistryItResolvesAgainst() public view {
        assertEq(address(pausable.accessRegistry()), address(registry));
    }

    function test_RoleGettersDefaultToTheCanonicalConstants() public view {
        assertEq(pausable.upgraderRole(), Roles.UPGRADER_ROLE);
        assertEq(pausable.criticalConfigRole(), Roles.CRITICAL_CONFIG_ROLE);
        assertEq(pausable.pauserRole(), Roles.PAUSER_ROLE);
        assertEq(pausable.unpauserRole(), Roles.UNPAUSER_ROLE);
    }

    function test_MembershipHelpersAgreeWithTheRegistry() public view {
        assertTrue(pausable.hasRoleView(Roles.PAUSER_ROLE, pauser));
        assertFalse(pausable.hasRoleView(Roles.PAUSER_ROLE, alice));

        pausable.requireRole(Roles.PAUSER_ROLE, pauser);
    }

    function test_RevertWhen_RequiredRoleIsMissing() public {
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.PAUSER_ROLE, alice)
        );
        pausable.requireRole(Roles.PAUSER_ROLE, alice);
    }

    function test_RevertWhen_InitialisedWithZeroRegistry() public {
        OperationPausableTester impl = new OperationPausableTester();

        vm.expectRevert(WithAccessRegistry.ZeroAccessRegistry.selector);
        _proxy(address(impl), abi.encodeCall(OperationPausableTester.initialize, (address(0), false)));
    }

    function test_RevertWhen_NonUpgraderUpgradesConsumerContract() public {
        OperationPausableTester nextImpl = new OperationPausableTester();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UPGRADER_ROLE, admin)
        );
        pausable.upgradeToAndCall(address(nextImpl), "");
    }

    function test_TimelockUpgradesConsumerContract() public {
        vm.prank(pauser);
        pausable.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        OperationPausableTester nextImpl = new OperationPausableTester();
        _executeViaTimelock(
            address(pausable),
            abi.encodeCall(pausable.upgradeToAndCall, (address(nextImpl), ""))
        );

        // An upgrade must never quietly reopen a flow an operator had stopped.
        assertTrue(pausable.isOperationPaused(Roles.OP_DEPOSIT_INSTANT));
    }
}
