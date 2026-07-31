// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Roles} from "../access/Roles.sol";
import {OperationPausable} from "../pause/OperationPausable.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @dev AggregatorV3-compatible feed whose NAV is posted by the issuer. The point is that the
///      posting key is not trusted: a deviation cap, a cooldown and absolute hard bounds each
///      constrain what a compromised feed operator can reach.
///
///      A move beyond the hard bounds cannot be posted until they are widened through the
///      timelock, so roughly 48h of fail-closed vault operation. Accepted knowingly; see
///      docs/FORKING.md on sizing them with real headroom rather than as a tight corridor.
contract AdminNavAggregator is
    Initializable,
    OperationPausable,
    UUPSUpgradeable,
    AggregatorV3Interface
{
    using SafeCast for uint256;

    /// @custom:storage-location erc7201:rwa.storage.AdminNavAggregator
    /// @dev `decimals`, `roundId` and `updatedAt` share one slot (8 + 80 + 48 bits) and every
    ///      NAV post writes the latter two together.
    struct AdminNavAggregatorStorage {
        uint8 decimals;
        uint80 roundId;
        uint48 updatedAt;
        int256 answer;
        uint256 deviationBps;
        uint256 updateCooldown;
        int256 minAnswer;
        int256 maxAnswer;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.AdminNavAggregator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ADMIN_NAV_AGGREGATOR_STORAGE_LOCATION =
        0x6464a4f3dba01eddf12b3f37c0b0bc424e2f248517d650ecdd96541347fe8800;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Not even a timelocked change may widen the cap past this, or "guardrails are
    ///      timelocked" would only mean "guardrails can be removed slowly".
    uint256 public constant MAX_DEVIATION_BPS = 2_000;

    /// @dev The opposite failure: a cooldown of years would strand the feed as stale.
    uint256 public constant MAX_UPDATE_COOLDOWN = 7 days;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /// @dev Distinct from {AnswerUpdated} so monitoring can alert on every deviation-cap bypass.
    event EmergencyAnswerPosted(int256 indexed current, int256 indexed previous, address indexed poster);

    event DeviationBpsUpdated(uint256 previousBps, uint256 newBps);
    event UpdateCooldownUpdated(uint256 previousCooldown, uint256 newCooldown);
    event HardBoundsUpdated(int256 minAnswer, int256 maxAnswer);

    error DeviationTooLarge(int256 previousAnswer, int256 newAnswer, uint256 deviationBps);

    error CooldownNotElapsed(uint256 nextAllowedAt);

    error AnswerOutOfBounds(int256 answer, int256 minAnswer, int256 maxAnswer);

    error ConfigOutOfRange();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param initialAnswer Must already sit inside the bounds; the feed is never left empty.
    /// @param minAnswer_ Must be positive. {DataFeed} rejects non-positive answers anyway.
    function initialize(
        address registry,
        uint8 decimals_,
        int256 initialAnswer,
        int256 minAnswer_,
        int256 maxAnswer_,
        uint256 deviationBps_,
        uint256 updateCooldown_,
        bool startPaused
    ) external initializer {
        __WithAccessRegistry_init(registry);

        AdminNavAggregatorStorage storage $ = _aggregatorStorage();
        // More than 18 would make every {DataFeed.getPrice} call revert in the converter,
        // bricking the feed with no way back short of an upgrade.
        if (decimals_ == 0 || decimals_ > 18) revert ConfigOutOfRange();
        $.decimals = decimals_;

        _setHardBounds($, minAnswer_, maxAnswer_);
        _setDeviationBps($, deviationBps_);
        _setUpdateCooldown($, updateCooldown_);

        _requireWithinBounds($, initialAnswer);
        $.answer = initialAnswer;
        $.updatedAt = block.timestamp.toUint48();
        $.roundId = 1;
        emit AnswerUpdated(initialAnswer, 1, block.timestamp);

        __OperationPausable_init(startPaused);
    }

    /// @inheritdoc OperationPausable
    function supportedOperations() public pure override returns (bytes32[] memory ops) {
        ops = new bytes32[](1);
        ops[0] = Roles.OP_ORACLE_UPDATE;
    }

    function feedOperatorRole() public view virtual returns (bytes32) {
        return Roles.FEED_OPERATOR_ROLE;
    }

    function feedAdminRole() public view virtual returns (bytes32) {
        return Roles.FEED_ADMIN_ROLE;
    }

    function setRoundDataSafe(
        int256 newAnswer
    ) external onlyRegistryRole(feedOperatorRole()) whenOperationNotPaused(Roles.OP_ORACLE_UPDATE) {
        AdminNavAggregatorStorage storage $ = _aggregatorStorage();

        uint256 nextAllowedAt = uint256($.updatedAt) + $.updateCooldown;
        if (block.timestamp < nextAllowedAt) revert CooldownNotElapsed(nextAllowedAt);

        int256 previous = $.answer;
        uint256 movement = _absDiff(previous, newAnswer);
        // `previous` is always positive: initialisation and both setters enforce bounds whose
        // floor is > 0, so this division is safe.
        if ((movement * BPS_DENOMINATOR) / uint256(previous) > $.deviationBps) {
            revert DeviationTooLarge(previous, newAnswer, $.deviationBps);
        }

        _post($, newAnswer);
    }

    /// @dev Bypasses the deviation cap and cooldown, never the hard bounds. A legitimate
    ///      multi-sigma move must be postable immediately: waiting out a cooldown during a
    ///      real repricing would strand the feed as stale.
    function setRoundData(
        int256 newAnswer
    ) external onlyRegistryRole(feedAdminRole()) whenOperationNotPaused(Roles.OP_ORACLE_UPDATE) {
        AdminNavAggregatorStorage storage $ = _aggregatorStorage();
        int256 previous = $.answer;

        _post($, newAnswer);
        emit EmergencyAnswerPosted(newAnswer, previous, msg.sender);
    }

    function setDeviationBps(uint256 newBps) external onlyRegistryRole(criticalConfigRole()) {
        _setDeviationBps(_aggregatorStorage(), newBps);
    }

    function setUpdateCooldown(uint256 newCooldown) external onlyRegistryRole(criticalConfigRole()) {
        _setUpdateCooldown(_aggregatorStorage(), newCooldown);
    }

    function setHardBounds(
        int256 newMinAnswer,
        int256 newMaxAnswer
    ) external onlyRegistryRole(criticalConfigRole()) {
        _setHardBounds(_aggregatorStorage(), newMinAnswer, newMaxAnswer);
    }

    function decimals() external view returns (uint8) {
        return _aggregatorStorage().decimals;
    }

    function description() external pure returns (string memory) {
        return "RWA admin-posted NAV aggregator";
    }

    function version() external pure returns (uint256) {
        return 3;
    }

    function deviationBps() external view returns (uint256) {
        return _aggregatorStorage().deviationBps;
    }

    function updateCooldown() external view returns (uint256) {
        return _aggregatorStorage().updateCooldown;
    }

    function hardBounds() external view returns (int256 minAnswer, int256 maxAnswer) {
        AdminNavAggregatorStorage storage $ = _aggregatorStorage();
        return ($.minAnswer, $.maxAnswer);
    }

    /// @dev Only the latest round is retained, so any `roundId_` resolves to the current
    ///      answer. Vaults read only `latestRoundData`.
    function getRoundData(
        uint80 roundId_
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        AdminNavAggregatorStorage storage $ = _aggregatorStorage();
        return (roundId_, $.answer, $.updatedAt, $.updatedAt, roundId_);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        AdminNavAggregatorStorage storage $ = _aggregatorStorage();
        return ($.roundId, $.answer, $.updatedAt, $.updatedAt, $.roundId);
    }

    function _post(AdminNavAggregatorStorage storage $, int256 newAnswer) private {
        _requireWithinBounds($, newAnswer);

        $.answer = newAnswer;
        $.updatedAt = block.timestamp.toUint48();
        uint80 nextRound = $.roundId + 1;
        $.roundId = nextRound;

        emit AnswerUpdated(newAnswer, nextRound, block.timestamp);
    }

    function _requireWithinBounds(AdminNavAggregatorStorage storage $, int256 candidate) private view {
        if (candidate < $.minAnswer || candidate > $.maxAnswer) {
            revert AnswerOutOfBounds(candidate, $.minAnswer, $.maxAnswer);
        }
    }

    function _setDeviationBps(AdminNavAggregatorStorage storage $, uint256 newBps) private {
        if (newBps == 0 || newBps > MAX_DEVIATION_BPS) revert ConfigOutOfRange();
        emit DeviationBpsUpdated($.deviationBps, newBps);
        $.deviationBps = newBps;
    }

    function _setUpdateCooldown(AdminNavAggregatorStorage storage $, uint256 newCooldown) private {
        // Zero would let updates be chained within one block, walking NAV to the edge of the
        // hard bounds in a single transaction.
        if (newCooldown == 0 || newCooldown > MAX_UPDATE_COOLDOWN) revert ConfigOutOfRange();
        emit UpdateCooldownUpdated($.updateCooldown, newCooldown);
        $.updateCooldown = newCooldown;
    }

    function _setHardBounds(
        AdminNavAggregatorStorage storage $,
        int256 newMinAnswer,
        int256 newMaxAnswer
    ) private {
        if (newMinAnswer <= 0 || newMinAnswer >= newMaxAnswer) revert ConfigOutOfRange();
        $.minAnswer = newMinAnswer;
        $.maxAnswer = newMaxAnswer;
        emit HardBoundsUpdated(newMinAnswer, newMaxAnswer);
    }

    function _absDiff(int256 a, int256 b) private pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }

    function _aggregatorStorage() private pure returns (AdminNavAggregatorStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ADMIN_NAV_AGGREGATOR_STORAGE_LOCATION
        }
    }

    function _authorizeUpgrade(address) internal override onlyRegistryRole(upgraderRole()) {}
}
