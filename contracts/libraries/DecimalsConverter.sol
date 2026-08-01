// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Converts between a payment token's native decimals and the internal WAD unit. Every
///      lossy conversion names its rounding direction in the function name, and there is no
///      direction-less `convert`: at a call site that moves money, rounding the wrong way is
///      a leak, and the direction should be auditable without reading the body.
///
///      Tokens above 18 decimals are rejected rather than down-scaled, which would make
///      `toWad` itself lossy.
library DecimalsConverter {
    error DecimalsTooHigh(uint8 tokenDecimals);

    uint8 internal constant WAD_DECIMALS = 18;

    function toWad(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        return amount * _scale(tokenDecimals);
    }

    /// @dev Rounds toward zero. Use when the protocol pays out: the remainder stays with the
    ///      protocol.
    function fromWadDown(uint256 wadAmount, uint8 tokenDecimals) internal pure returns (uint256) {
        return wadAmount / _scale(tokenDecimals);
    }

    function _scale(uint8 tokenDecimals) private pure returns (uint256) {
        if (tokenDecimals > WAD_DECIMALS) revert DecimalsTooHigh(tokenDecimals);
        return 10 ** (WAD_DECIMALS - tokenDecimals);
    }
}
