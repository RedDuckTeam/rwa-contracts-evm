// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DecimalsConverter} from "../libraries/DecimalsConverter.sol";

/// @dev A library's internal functions are inlined into the caller, so a revert inside one is
///      not an external call and `expectRevert` cannot observe it. These wrappers make every
///      branch reachable from a test.
contract DecimalsConverterTester {
    function toWad(uint256 amount, uint8 tokenDecimals) external pure returns (uint256) {
        return DecimalsConverter.toWad(amount, tokenDecimals);
    }

    function fromWadDown(uint256 wadAmount, uint8 tokenDecimals) external pure returns (uint256) {
        return DecimalsConverter.fromWadDown(wadAmount, tokenDecimals);
    }

    function wadDecimals() external pure returns (uint8) {
        return DecimalsConverter.WAD_DECIMALS;
    }
}
