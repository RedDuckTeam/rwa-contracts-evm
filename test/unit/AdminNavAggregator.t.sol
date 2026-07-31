// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {WithAccessRegistry} from "../../contracts/access/WithAccessRegistry.sol";
import {OperationPausable} from "../../contracts/pause/OperationPausable.sol";
import {AdminNavAggregator} from "../../contracts/oracle/AdminNavAggregator.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract AdminNavAggregatorTest is PlatformFixture {
    function setUp() public {
        _deployAccessLayer();
        _deployOracle(false);
        _grantOperational(Roles.PAUSER_ROLE, pauser);
        _grantOperational(Roles.UNPAUSER_ROLE, unpauser);
    }

    function test_InitialiseSetsFeedShapeAndGuardrails() public view {
        assertEq(aggregator.decimals(), FEED_DECIMALS);
        assertEq(aggregator.version(), 3);
        assertEq(aggregator.deviationBps(), DEVIATION_BPS);
        assertEq(aggregator.updateCooldown(), UPDATE_COOLDOWN);

        (int256 minAnswer, int256 maxAnswer) = aggregator.hardBounds();
        assertEq(minAnswer, NAV_HARD_MIN);
        assertEq(maxAnswer, NAV_HARD_MAX);

        (uint80 roundId, int256 answer, , uint256 updatedAt, ) = aggregator.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, INITIAL_NAV);
        assertEq(updatedAt, block.timestamp);
    }

    /// @dev An unposted aggregator would report `answer == 0`, and a consumer that skipped the
    ///      sign check would price at zero.
    function test_RevertWhen_InitialAnswerIsOutsideTheHardBounds() public {
        AdminNavAggregator impl = new AdminNavAggregator();

        vm.expectRevert(
            abi.encodeWithSelector(
                AdminNavAggregator.AnswerOutOfBounds.selector,
                int256(0.1e8),
                NAV_HARD_MIN,
                NAV_HARD_MAX
            )
        );
        _proxy(
            address(impl),
            abi.encodeCall(
                AdminNavAggregator.initialize,
                (
                    address(registry),
                    FEED_DECIMALS,
                    int256(0.1e8),
                    NAV_HARD_MIN,
                    NAV_HARD_MAX,
                    DEVIATION_BPS,
                    UPDATE_COOLDOWN,
                    false
                )
            )
        );
    }

    function test_RevertWhen_InitialConfigIsOutOfRange() public {
        AdminNavAggregator impl = new AdminNavAggregator();

        // min >= max
        vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
        _proxy(
            address(impl),
            abi.encodeCall(
                AdminNavAggregator.initialize,
                (
                    address(registry),
                    FEED_DECIMALS,
                    INITIAL_NAV,
                    NAV_HARD_MAX,
                    NAV_HARD_MIN,
                    DEVIATION_BPS,
                    UPDATE_COOLDOWN,
                    false
                )
            )
        );

        // a floor of zero would let NAV legitimately reach zero
        vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
        _proxy(
            address(impl),
            abi.encodeCall(
                AdminNavAggregator.initialize,
                (
                    address(registry),
                    FEED_DECIMALS,
                    INITIAL_NAV,
                    int256(0),
                    NAV_HARD_MAX,
                    DEVIATION_BPS,
                    UPDATE_COOLDOWN,
                    false
                )
            )
        );
    }

    function test_RevertWhen_ImplementationIsInitialisedDirectly() public {
        AdminNavAggregator impl = new AdminNavAggregator();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            address(registry),
            FEED_DECIMALS,
            INITIAL_NAV,
            NAV_HARD_MIN,
            NAV_HARD_MAX,
            DEVIATION_BPS,
            UPDATE_COOLDOWN,
            false
        );
    }

    function test_DeploysWithNavPostingPausedForProduction() public {
        _deployOracle(true);
        assertTrue(aggregator.isOperationPaused(Roles.OP_ORACLE_UPDATE));
    }

    function test_OperatorPostsWithinDeviationAfterCooldown() public {
        vm.warp(block.timestamp + UPDATE_COOLDOWN);

        vm.prank(feedOperator);
        aggregator.setRoundDataSafe(1.01e8); // exactly +1%

        (uint80 roundId, int256 answer, , , ) = aggregator.latestRoundData();
        assertEq(answer, 1.01e8);
        assertEq(roundId, 2);
    }

    function test_EmitsAnswerUpdated() public {
        vm.warp(block.timestamp + UPDATE_COOLDOWN);

        vm.expectEmit(true, true, false, true, address(aggregator));
        emit AdminNavAggregator.AnswerUpdated(1.005e8, 2, block.timestamp);

        vm.prank(feedOperator);
        aggregator.setRoundDataSafe(1.005e8);
    }

    /// @dev The cap turns "the NAV key is compromised" into a bounded, slow drift rather than an
    ///      instant repricing to any value inside the bounds.
    function test_RevertWhen_DeviationExceedsTheCap() public {
        vm.warp(block.timestamp + UPDATE_COOLDOWN);

        vm.prank(feedOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AdminNavAggregator.DeviationTooLarge.selector,
                INITIAL_NAV,
                int256(1.0101e8),
                DEVIATION_BPS
            )
        );
        aggregator.setRoundDataSafe(1.0101e8);
    }

    function test_DeviationCapAppliesDownwardsToo() public {
        vm.warp(block.timestamp + UPDATE_COOLDOWN);

        vm.prank(feedOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AdminNavAggregator.DeviationTooLarge.selector,
                INITIAL_NAV,
                int256(0.98e8),
                DEVIATION_BPS
            )
        );
        aggregator.setRoundDataSafe(0.98e8);

        vm.prank(feedOperator);
        aggregator.setRoundDataSafe(0.99e8); // exactly -1%
    }

    /// @dev Without it, an attacker could chain many within-cap updates in one transaction and
    ///      reach any price inside the hard bounds instantly.
    function test_RevertWhen_CooldownHasNotElapsed() public {
        (, , , uint256 updatedAt, ) = aggregator.latestRoundData();

        vm.warp(block.timestamp + UPDATE_COOLDOWN - 1);
        vm.prank(feedOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AdminNavAggregator.CooldownNotElapsed.selector,
                updatedAt + UPDATE_COOLDOWN
            )
        );
        aggregator.setRoundDataSafe(1.001e8);
    }

    function test_ReachingADistantPriceTakesRealTime() public {
        // 1% per hour: 1.00 to ~1.05 costs five hours of wall clock, which is the window an
        // operator has to notice and pause.
        int256 expected = INITIAL_NAV;
        for (uint256 i; i < 5; ++i) {
            expected = (expected * 101) / 100;
            _postNav(expected);
        }

        (, int256 answer, , , ) = aggregator.latestRoundData();
        assertEq(answer, expected);
        assertGt(answer, 1.05e8);
        assertLt(answer, 1.06e8);
    }

    function test_AdminBypassesDeviationAndCooldown() public {
        // No warp: the cooldown has not elapsed, and the move is far beyond 1%.
        vm.prank(feedAdmin);
        aggregator.setRoundData(5e8);

        (, int256 answer, , , ) = aggregator.latestRoundData();
        assertEq(answer, 5e8);
    }

    /// @dev Its own event on top of the Chainlink-shaped one, so monitoring can alert on every
    ///      deviation-cap bypass.
    function test_EmergencyPostEmitsADistinctEvent() public {
        vm.expectEmit(true, true, true, false, address(aggregator));
        emit AdminNavAggregator.EmergencyAnswerPosted(5e8, INITIAL_NAV, feedAdmin);

        vm.prank(feedAdmin);
        aggregator.setRoundData(5e8);
    }

    /// @dev The one constraint the emergency path does not skip.
    function test_RevertWhen_EmergencyPostLeavesTheHardBounds() public {
        vm.prank(feedAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AdminNavAggregator.AnswerOutOfBounds.selector,
                int256(11e8),
                NAV_HARD_MIN,
                NAV_HARD_MAX
            )
        );
        aggregator.setRoundData(11e8);
    }

    function test_RevertWhen_RoutinePostLeavesTheHardBounds() public {
        // Walk NAV to the floor, then step past it while still inside the deviation cap: the
        // bounds check has to fire independently of the cap.
        _executeViaTimelock(
            address(aggregator),
            abi.encodeCall(aggregator.setHardBounds, (int256(0.995e8), NAV_HARD_MAX))
        );

        vm.warp(block.timestamp + UPDATE_COOLDOWN);
        vm.prank(feedOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AdminNavAggregator.AnswerOutOfBounds.selector,
                int256(0.99e8),
                int256(0.995e8),
                NAV_HARD_MAX
            )
        );
        aggregator.setRoundDataSafe(0.99e8);
    }

    function test_RevertWhen_OperatorUsesTheEmergencyPath() public {
        vm.prank(feedOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.FEED_ADMIN_ROLE,
                feedOperator
            )
        );
        aggregator.setRoundData(5e8);
    }

    function test_RevertWhen_AdminUsesTheRoutinePath() public {
        vm.warp(block.timestamp + UPDATE_COOLDOWN);
        vm.prank(feedAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.FEED_OPERATOR_ROLE,
                feedAdmin
            )
        );
        aggregator.setRoundDataSafe(1.005e8);
    }

    function test_RoleGettersDefaultToTheCanonicalConstants() public view {
        assertEq(aggregator.feedOperatorRole(), Roles.FEED_OPERATOR_ROLE);
        assertEq(aggregator.feedAdminRole(), Roles.FEED_ADMIN_ROLE);
    }

    /// @dev The fastest countermeasure against a compromised feed key: any PAUSER holder stops
    ///      BOTH posting paths immediately, with no timelock.
    function test_PauseStopsBothPostingPaths() public {
        vm.prank(pauser);
        aggregator.pauseOperation(Roles.OP_ORACLE_UPDATE);

        vm.warp(block.timestamp + UPDATE_COOLDOWN);

        vm.prank(feedOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                OperationPausable.OperationIsPaused.selector,
                Roles.OP_ORACLE_UPDATE
            )
        );
        aggregator.setRoundDataSafe(1.005e8);

        vm.prank(feedAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                OperationPausable.OperationIsPaused.selector,
                Roles.OP_ORACLE_UPDATE
            )
        );
        aggregator.setRoundData(1.005e8);
    }

    function test_UnpauseRestoresPosting() public {
        vm.prank(pauser);
        aggregator.pauseOperation(Roles.OP_ORACLE_UPDATE);
        vm.prank(unpauser);
        aggregator.unpauseOperation(Roles.OP_ORACLE_UPDATE);

        _postNav(1.005e8);
        (, int256 answer, , , ) = aggregator.latestRoundData();
        assertEq(answer, 1.005e8);
    }

    function test_OnlyOracleUpdateIsPausableHere() public view {
        bytes32[] memory ops = aggregator.supportedOperations();
        assertEq(ops.length, 1);
        assertEq(ops[0], Roles.OP_ORACLE_UPDATE);
    }

    function test_TimelockAdjustsGuardrails() public {
        _executeViaTimelock(address(aggregator), abi.encodeCall(aggregator.setDeviationBps, (250)));
        assertEq(aggregator.deviationBps(), 250);

        _executeViaTimelock(address(aggregator), abi.encodeCall(aggregator.setUpdateCooldown, (2 hours)));
        assertEq(aggregator.updateCooldown(), 2 hours);

        _executeViaTimelock(
            address(aggregator),
            abi.encodeCall(aggregator.setHardBounds, (int256(0.1e8), int256(100e8)))
        );
        (int256 minAnswer, int256 maxAnswer) = aggregator.hardBounds();
        assertEq(minAnswer, 0.1e8);
        assertEq(maxAnswer, 100e8);
    }

    /// @dev Whoever holds the feed keys must not be able to loosen the limits on those keys.
    function test_RevertWhen_GuardrailsAreChangedOutsideTheTimelock() public {
        vm.prank(feedAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                feedAdmin
            )
        );
        aggregator.setDeviationBps(2_000);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                admin
            )
        );
        aggregator.setHardBounds(int256(1), int256(type(int128).max));
    }

    /// @dev Otherwise "timelocked guardrails" would only mean "guardrails removable slowly".
    function test_RevertWhen_ConfigWouldExceedItsCodedCap() public {
        // Read the caps before arming the expectation: an external call placed after
        // `expectRevert` is the call it matches against.
        uint256 maxDeviation = aggregator.MAX_DEVIATION_BPS();
        uint256 maxCooldown = aggregator.MAX_UPDATE_COOLDOWN();

        vm.startPrank(address(timelock));

        vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
        aggregator.setDeviationBps(maxDeviation + 1);

        vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
        aggregator.setDeviationBps(0);

        vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
        aggregator.setUpdateCooldown(maxCooldown + 1);

        vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
        aggregator.setHardBounds(int256(2e8), int256(1e8));

        vm.stopPrank();
    }

    /// @dev Zero would let updates be chained inside a single block, walking NAV to the edge of
    ///      the hard bounds in one transaction instead of over hours.
    function test_RevertWhen_CooldownWouldBeZero() public {
        vm.prank(address(timelock));
        vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
        aggregator.setUpdateCooldown(0);

        assertEq(aggregator.updateCooldown(), UPDATE_COOLDOWN);
    }

    /// @dev More than 18 would make every {DataFeed.getPrice} call revert in the converter,
    ///      bricking the deployment with no way back short of an upgrade.
    function test_RevertWhen_FeedDecimalsAreUnusable() public {
        AdminNavAggregator impl = new AdminNavAggregator();

        for (uint8 badDecimals = 0; badDecimals < 2; ++badDecimals) {
            uint8 value = badDecimals == 0 ? 0 : 19;
            vm.expectRevert(AdminNavAggregator.ConfigOutOfRange.selector);
            _proxy(
                address(impl),
                abi.encodeCall(
                    AdminNavAggregator.initialize,
                    (
                        address(registry),
                        value,
                        INITIAL_NAV,
                        NAV_HARD_MIN,
                        NAV_HARD_MAX,
                        DEVIATION_BPS,
                        UPDATE_COOLDOWN,
                        false
                    )
                )
            );
        }
    }

    /// @dev Only the latest round is retained, so every id resolves to the current answer.
    function test_GetRoundDataReturnsTheLatestAnswerForAnyId() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) = aggregator
            .getRoundData(42);

        assertEq(roundId, 42);
        assertEq(answeredIn, 42);
        assertEq(answer, INITIAL_NAV);
        assertEq(startedAt, updatedAt);
    }

    function test_DescriptionIsSet() public view {
        assertEq(aggregator.description(), "RWA admin-posted NAV aggregator");
    }

    /// @dev No accepted answer may be further than the cap from the previous one, or outside
    ///      the bounds.
    function testFuzz_RoutinePathNeverExceedsCapOrBounds(int256 candidate) public {
        candidate = bound(candidate, -1e12, 1e12);
        (, int256 previous, , , ) = aggregator.latestRoundData();

        vm.warp(block.timestamp + UPDATE_COOLDOWN);
        vm.prank(feedOperator);
        try aggregator.setRoundDataSafe(candidate) {
            uint256 movement = candidate >= previous
                ? uint256(candidate - previous)
                : uint256(previous - candidate);
            assertLe((movement * 10_000) / uint256(previous), DEVIATION_BPS);
            assertGe(candidate, NAV_HARD_MIN);
            assertLe(candidate, NAV_HARD_MAX);
        } catch {
            // Rejected: nothing to assert beyond the answer being untouched.

            (, int256 unchangedAnswer, , , ) = aggregator.latestRoundData();
            assertEq(unchangedAnswer, previous);
        }
    }

    /// @dev The emergency path skips the cap but never the bounds.
    function testFuzz_EmergencyPathStillRespectsBounds(int256 candidate) public {
        candidate = bound(candidate, -1e12, 1e12);

        vm.prank(feedAdmin);
        try aggregator.setRoundData(candidate) {
            assertGe(candidate, NAV_HARD_MIN);
            assertLe(candidate, NAV_HARD_MAX);
        } catch {
            assertTrue(candidate < NAV_HARD_MIN || candidate > NAV_HARD_MAX);
        }
    }

    function test_RevertWhen_NonUpgraderUpgradesAggregator() public {
        AdminNavAggregator nextImpl = new AdminNavAggregator();

        vm.prank(feedAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UPGRADER_ROLE, feedAdmin)
        );
        aggregator.upgradeToAndCall(address(nextImpl), "");
    }

    function test_TimelockUpgradesAggregatorAndStatePersists() public {
        _postNav(1.01e8);

        AdminNavAggregator nextImpl = new AdminNavAggregator();
        _executeViaTimelock(
            address(aggregator),
            abi.encodeCall(aggregator.upgradeToAndCall, (address(nextImpl), ""))
        );

        (, int256 answer, , , ) = aggregator.latestRoundData();
        assertEq(answer, 1.01e8);
        assertEq(aggregator.deviationBps(), DEVIATION_BPS);
    }
}
