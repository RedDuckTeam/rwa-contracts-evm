// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRwaToken is IERC20 {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    /// @dev Bypasses the transfer pause and the blacklist, but not sanctions.
    function refundFromVault(address to, uint256 amount) external returns (bool);
}
