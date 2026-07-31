// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {WithAccessRegistry} from "../../contracts/access/WithAccessRegistry.sol";
import {DecimalsConverter} from "../../contracts/libraries/DecimalsConverter.sol";
import {DataFeed} from "../../contracts/oracle/DataFeed.sol";
import {MockAggregator} from "../../contracts/mocks/MockAggregator.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract DataFeedTest is PlatformFixture {
    MockAggregator internal mockFeed;

    function setUp() public {
        _deployAccessLayer();
        _deployOracle(false);

        mockFeed = new MockAggregator(FEED_DECIMALS, INITIAL_NAV);
    }

    /// @dev Repoints at the freely-controllable mock, so tests can drive states the real
    ///      aggregator's guardrails would refuse to produce.
    function _useMockAggregator() internal {
        _executeViaTimelock(address(dataFeed), abi.encodeCall(dataFeed.setAggregator, (address(mockFeed))));
    }

    function test_InitialiseWiresAggregatorAndPolicy() public view {
        assertEq(dataFeed.aggregator(), address(aggregator));
        assertEq(dataFeed.healthyDiff(), HEALTHY_DIFF);

        (uint256 minPrice, uint256 maxPrice) = dataFeed.priceBounds();
        assertEq(minPrice, PRICE_MIN_WAD);
        assertEq(maxPrice, PRICE_MAX_WAD);
    }

    function test_RevertWhen_ImplementationIsInitialisedDirectly() public {
        DataFeed impl = new DataFeed();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(registry), address(aggregator), HEALTHY_DIFF, PRICE_MIN_WAD, PRICE_MAX_WAD);
    }

    function test_RevertWhen_InitialConfigIsUnusable() public {
        DataFeed impl = new DataFeed();

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        _proxy(
            address(impl),
            abi.encodeCall(
                DataFeed.initialize,
                (address(registry), address(0), HEALTHY_DIFF, PRICE_MIN_WAD, PRICE_MAX_WAD)
            )
        );

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        _proxy(
            address(impl),
            abi.encodeCall(
                DataFeed.initialize,
                (address(registry), address(aggregator), 0, PRICE_MIN_WAD, PRICE_MAX_WAD)
            )
        );

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        _proxy(
            address(impl),
            abi.encodeCall(
                DataFeed.initialize,
                (address(registry), address(aggregator), HEALTHY_DIFF, PRICE_MAX_WAD, PRICE_MIN_WAD)
            )
        );
    }

    function test_ConvertsFeedDecimalsToWad() public view {
        // 1.00 at 8 decimals becomes 1e18.
        assertEq(dataFeed.getPrice(), 1e18);
    }

    /// @dev Read on every call: a cached value would keep the old scale after an aggregator swap
    ///      and misprice by orders of magnitude — here, by 1e10.
    function test_ReadsAggregatorDecimalsDynamically() public {
        _useMockAggregator();
        assertEq(dataFeed.getPrice(), 1e18);

        mockFeed.setDecimals(18);
        mockFeed.setAnswer(2e18);
        assertEq(dataFeed.getPrice(), 2e18);

        mockFeed.setDecimals(6);
        mockFeed.setAnswer(3e6);
        assertEq(dataFeed.getPrice(), 3e18);
    }

    function test_RevertWhen_AggregatorReportsMoreThan18Decimals() public {
        _useMockAggregator();
        mockFeed.setDecimals(19);

        vm.expectRevert(abi.encodeWithSelector(DecimalsConverter.DecimalsTooHigh.selector, uint8(19)));
        dataFeed.getPrice();
    }

    /// @dev A feed that stops updating returns its last answer forever, and it looks perfectly
    ///      valid. Only the timestamp gives it away.
    function test_RevertWhen_PriceIsStale() public {
        (, , , uint256 updatedAt, ) = aggregator.latestRoundData();

        vm.warp(updatedAt + HEALTHY_DIFF);
        dataFeed.getPrice(); // exactly at the edge is still healthy

        vm.warp(updatedAt + HEALTHY_DIFF + 1);
        vm.expectRevert(abi.encodeWithSelector(DataFeed.StalePrice.selector, updatedAt, HEALTHY_DIFF));
        dataFeed.getPrice();
    }

    /// @dev The answer is SIGNED; casting a negative one to unsigned yields a near-max price, so
    ///      the sign check has to come first.
    function test_RevertWhen_AnswerIsZeroOrNegative() public {
        _useMockAggregator();

        mockFeed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(DataFeed.NonPositivePrice.selector, int256(0)));
        dataFeed.getPrice();

        mockFeed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(DataFeed.NonPositivePrice.selector, int256(-1)));
        dataFeed.getPrice();
    }

    /// @dev A second band, in WAD, that survives an aggregator swap — so a replacement feed with
    ///      broken scaling is still caught.
    function test_RevertWhen_PriceLeavesTheWadBand() public {
        _useMockAggregator();

        mockFeed.setAnswer(0.4e8);
        vm.expectRevert(
            abi.encodeWithSelector(DataFeed.PriceOutOfBounds.selector, 0.4e18, PRICE_MIN_WAD, PRICE_MAX_WAD)
        );
        dataFeed.getPrice();

        mockFeed.setAnswer(11e8);
        vm.expectRevert(
            abi.encodeWithSelector(DataFeed.PriceOutOfBounds.selector, 11e18, PRICE_MIN_WAD, PRICE_MAX_WAD)
        );
        dataFeed.getPrice();
    }

    /// @dev The two bound sets live in different units and must describe the same band. A
    ///      mismatch means the aggregator accepts prices the DataFeed then refuses: healthy to
    ///      the operator, dead to the vaults.
    function test_AggregatorAndFeedBoundsDescribeTheSameBand() public view {
        (int256 navMin, int256 navMax) = aggregator.hardBounds();
        (uint256 wadMin, uint256 wadMax) = dataFeed.priceBounds();

        assertEq(DecimalsConverter.toWad(uint256(navMin), FEED_DECIMALS), wadMin);
        assertEq(DecimalsConverter.toWad(uint256(navMax), FEED_DECIMALS), wadMax);
    }

    function test_IsHealthyReportsWithoutReverting() public {
        assertTrue(dataFeed.isHealthy());

        _useMockAggregator();
        mockFeed.setAnswer(-5);
        assertFalse(dataFeed.isHealthy());

        mockFeed.setAnswer(1e8);
        assertTrue(dataFeed.isHealthy());

        vm.warp(block.timestamp + HEALTHY_DIFF + 1);
        assertFalse(dataFeed.isHealthy());
    }

    /// @dev The whole point of the adapter: replacing the price source touches no vault.
    function test_TimelockSwapsTheAggregator() public {
        MockAggregator replacement = new MockAggregator(FEED_DECIMALS, 2e8);

        _executeViaTimelock(
            address(dataFeed),
            abi.encodeCall(dataFeed.setAggregator, (address(replacement)))
        );

        assertEq(dataFeed.aggregator(), address(replacement));
        assertEq(dataFeed.getPrice(), 2e18);
    }

    function test_EmitsAggregatorUpdateEvent() public {
        bytes memory payload = abi.encodeCall(dataFeed.setAggregator, (address(mockFeed)));
        _scheduleViaTimelock(address(dataFeed), payload);

        vm.expectEmit(true, true, false, false, address(dataFeed));
        emit DataFeed.AggregatorUpdated(address(aggregator), address(mockFeed));
        _executeScheduled(address(dataFeed), payload);
    }

    function test_RevertWhen_AggregatorIsSwappedOutsideTheTimelock() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                admin
            )
        );
        dataFeed.setAggregator(address(mockFeed));
    }

    function test_TimelockAdjustsPolicy() public {
        _executeViaTimelock(address(dataFeed), abi.encodeCall(dataFeed.setHealthyDiff, (1 days)));
        assertEq(dataFeed.healthyDiff(), 1 days);

        _executeViaTimelock(
            address(dataFeed),
            abi.encodeCall(dataFeed.setPriceBounds, (0.1e18, 100e18))
        );
        (uint256 minPrice, uint256 maxPrice) = dataFeed.priceBounds();
        assertEq(minPrice, 0.1e18);
        assertEq(maxPrice, 100e18);
    }

    function test_RevertWhen_PolicyIsChangedOutsideTheTimelock() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                admin
            )
        );
        dataFeed.setHealthyDiff(1 days);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                admin
            )
        );
        dataFeed.setPriceBounds(1, type(uint128).max);
    }

    function test_RevertWhen_PolicyWouldExceedItsCodedCap() public {
        uint256 maxHealthyDiff = dataFeed.MAX_HEALTHY_DIFF();

        vm.startPrank(address(timelock));

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        dataFeed.setHealthyDiff(maxHealthyDiff + 1);

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        dataFeed.setHealthyDiff(0);

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        dataFeed.setPriceBounds(0, 1e18);

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        dataFeed.setPriceBounds(2e18, 1e18);

        vm.expectRevert(DataFeed.ConfigOutOfRange.selector);
        dataFeed.setAggregator(address(0));

        vm.stopPrank();
    }

    /// @dev Whatever the aggregator reports, `getPrice` returns a value inside the band or
    ///      reverts. It must never return an out-of-band price.
    function testFuzz_PriceIsEitherInBandOrRejected(int256 answer, uint8 feedDecimals) public {
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        answer = bound(answer, -1e30, 1e30);

        _useMockAggregator();
        mockFeed.setDecimals(feedDecimals);
        mockFeed.setAnswer(answer);

        try dataFeed.getPrice() returns (uint256 priceWad) {
            assertGe(priceWad, PRICE_MIN_WAD);
            assertLe(priceWad, PRICE_MAX_WAD);
            assertGt(answer, 0);
        } catch {
            // Rejected — acceptable for any input.
        }
    }

    /// @dev Freshness is judged only by the timestamp, independent of the value.
    function testFuzz_StalenessDependsOnlyOnAge(uint256 age) public {
        age = bound(age, 0, 365 days);
        _useMockAggregator();

        uint256 postedAt = block.timestamp;
        mockFeed.setAnswerWithTimestamp(1e8, postedAt);
        vm.warp(postedAt + age);

        try dataFeed.getPrice() {
            assertLe(age, HEALTHY_DIFF);
        } catch {
            assertGt(age, HEALTHY_DIFF);
        }
    }

    function test_RevertWhen_NonUpgraderUpgradesFeed() public {
        DataFeed nextImpl = new DataFeed();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UPGRADER_ROLE, admin)
        );
        dataFeed.upgradeToAndCall(address(nextImpl), "");
    }

    function test_TimelockUpgradesFeedAndStatePersists() public {
        DataFeed nextImpl = new DataFeed();
        _executeViaTimelock(
            address(dataFeed),
            abi.encodeCall(dataFeed.upgradeToAndCall, (address(nextImpl), ""))
        );

        assertEq(dataFeed.aggregator(), address(aggregator));
        assertEq(dataFeed.healthyDiff(), HEALTHY_DIFF);
        assertEq(dataFeed.getPrice(), 1e18);
    }
}
