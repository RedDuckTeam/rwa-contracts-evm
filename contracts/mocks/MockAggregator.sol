// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

contract MockAggregator is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(uint8 decimals_, int256 initialAnswer) {
        _decimals = decimals_;
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function setDecimals(uint8 newDecimals) external {
        _decimals = newDecimals;
    }

    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
        _updatedAt = block.timestamp;
        ++_roundId;
    }

    /// @dev Posts a stale or future-dated round without warping the chain.
    function setAnswerWithTimestamp(int256 newAnswer, uint256 updatedAt) external {
        _answer = newAnswer;
        _updatedAt = updatedAt;
        ++_roundId;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "MockAggregator";
    }

    function version() external pure returns (uint256) {
        return 3;
    }

    function getRoundData(
        uint80 roundId_
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId_, _answer, _updatedAt, _updatedAt, roundId_);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
