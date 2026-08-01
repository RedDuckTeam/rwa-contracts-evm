// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Vaults never touch an aggregator directly. Freshness, sign, magnitude and unit are
///      all enforced behind this, so swapping the bundled aggregator for a third-party feed
///      changes no vault code.
interface IDataFeed {
    /// @dev Reverts unless the price is healthy. There is no "return zero on failure"
    ///      variant: every caller moves money.
    function getPrice() external view returns (uint256 priceWad);
}
