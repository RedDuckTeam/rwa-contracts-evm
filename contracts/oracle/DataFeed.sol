// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {WithAccessRegistry} from "../access/WithAccessRegistry.sol";
import {DecimalsConverter} from "../libraries/DecimalsConverter.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IDataFeed} from "../interfaces/IDataFeed.sol";

/// @dev The adapter seam: vaults depend on {IDataFeed} and nothing else, so a fork can point
///      this at a Chainlink feed or the bundled {AdminNavAggregator} without re-auditing a
///      vault. Four rejections, each for a failure the design would otherwise inherit:
///      * STALE - an aggregator that stops updating returns its last answer forever, and it
///        looks perfectly valid.
///      * NON-POSITIVE - the answer is SIGNED; a negative value cast to unsigned becomes an
///        astronomically large price.
///      * OUT OF BOUNDS - a second band, in WAD, that survives an aggregator swap and so
///        catches a replacement feed with broken scaling.
///      * DECIMALS - read on every call, never cached: a cached value silently misprices by
///        orders of magnitude after a swap.
contract DataFeed is Initializable, WithAccessRegistry, UUPSUpgradeable, IDataFeed {
    /// @custom:storage-location erc7201:rwa.storage.DataFeed
    struct DataFeedStorage {
        AggregatorV3Interface aggregator;
        uint256 healthyDiff;
        uint256 minPriceWad;
        uint256 maxPriceWad;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.DataFeed")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DATA_FEED_STORAGE_LOCATION =
        0x82159a21b1f286dcf96d39a59fbaf3fcd52784484e22277947c5676806a1cb00;

    /// @dev A `healthyDiff` of years would make the staleness check decorative.
    uint256 public constant MAX_HEALTHY_DIFF = 30 days;

    event AggregatorUpdated(address indexed previousAggregator, address indexed newAggregator);
    event HealthyDiffUpdated(uint256 previousHealthyDiff, uint256 newHealthyDiff);
    event PriceBoundsUpdated(uint256 minPriceWad, uint256 maxPriceWad);

    error StalePrice(uint256 updatedAt, uint256 healthyDiff);

    error NonPositivePrice(int256 answer);

    error PriceOutOfBounds(uint256 priceWad, uint256 minPriceWad, uint256 maxPriceWad);

    error ConfigOutOfRange();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address registry,
        address aggregator_,
        uint256 healthyDiff_,
        uint256 minPriceWad_,
        uint256 maxPriceWad_
    ) external initializer {
        __WithAccessRegistry_init(registry);

        DataFeedStorage storage $ = _dataFeedStorage();
        _setAggregator($, aggregator_);
        _setHealthyDiff($, healthyDiff_);
        _setPriceBounds($, minPriceWad_, maxPriceWad_);
    }

    /// @inheritdoc IDataFeed
    function getPrice() external view returns (uint256 priceWad) {
        DataFeedStorage storage $ = _dataFeedStorage();

        // Freshness is judged by `updatedAt`; `answeredInRound` is a pre-OCR Chainlink
        // artefact and is not meaningful on modern feeds.
        // slither-disable-next-line unused-return
        (, int256 answer, , uint256 updatedAt, ) = $.aggregator.latestRoundData();

        if (answer <= 0) revert NonPositivePrice(answer);
        if (block.timestamp > updatedAt + $.healthyDiff) revert StalePrice(updatedAt, $.healthyDiff);

        priceWad = DecimalsConverter.toWad(uint256(answer), $.aggregator.decimals());

        if (priceWad < $.minPriceWad || priceWad > $.maxPriceWad) {
            revert PriceOutOfBounds(priceWad, $.minPriceWad, $.maxPriceWad);
        }
    }

    /// @dev Non-reverting, for deployment verification and monitoring. Money paths call
    ///      {getPrice} so a stale feed stops them rather than being quietly observed.
    function isHealthy() external view returns (bool) {
        // slither-disable-next-line unused-return
        try this.getPrice() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev The adapter swap: replaces the source of every price the platform trades on.
    function setAggregator(address newAggregator) external onlyRegistryRole(criticalConfigRole()) {
        _setAggregator(_dataFeedStorage(), newAggregator);
    }

    function setHealthyDiff(uint256 newHealthyDiff) external onlyRegistryRole(criticalConfigRole()) {
        _setHealthyDiff(_dataFeedStorage(), newHealthyDiff);
    }

    function setPriceBounds(
        uint256 newMinPriceWad,
        uint256 newMaxPriceWad
    ) external onlyRegistryRole(criticalConfigRole()) {
        _setPriceBounds(_dataFeedStorage(), newMinPriceWad, newMaxPriceWad);
    }

    function aggregator() external view returns (address) {
        return address(_dataFeedStorage().aggregator);
    }

    function healthyDiff() external view returns (uint256) {
        return _dataFeedStorage().healthyDiff;
    }

    function priceBounds() external view returns (uint256 minPriceWad, uint256 maxPriceWad) {
        DataFeedStorage storage $ = _dataFeedStorage();
        return ($.minPriceWad, $.maxPriceWad);
    }

    function _setAggregator(DataFeedStorage storage $, address newAggregator) private {
        if (newAggregator == address(0)) revert ConfigOutOfRange();
        emit AggregatorUpdated(address($.aggregator), newAggregator);
        $.aggregator = AggregatorV3Interface(newAggregator);
    }

    function _setHealthyDiff(DataFeedStorage storage $, uint256 newHealthyDiff) private {
        if (newHealthyDiff == 0 || newHealthyDiff > MAX_HEALTHY_DIFF) revert ConfigOutOfRange();
        emit HealthyDiffUpdated($.healthyDiff, newHealthyDiff);
        $.healthyDiff = newHealthyDiff;
    }

    function _setPriceBounds(
        DataFeedStorage storage $,
        uint256 newMinPriceWad,
        uint256 newMaxPriceWad
    ) private {
        if (newMinPriceWad == 0 || newMinPriceWad >= newMaxPriceWad) revert ConfigOutOfRange();
        $.minPriceWad = newMinPriceWad;
        $.maxPriceWad = newMaxPriceWad;
        emit PriceBoundsUpdated(newMinPriceWad, newMaxPriceWad);
    }

    function _dataFeedStorage() private pure returns (DataFeedStorage storage $) {
        assembly ("memory-safe") {
            $.slot := DATA_FEED_STORAGE_LOCATION
        }
    }

    function _authorizeUpgrade(address) internal override onlyRegistryRole(upgraderRole()) {}
}
