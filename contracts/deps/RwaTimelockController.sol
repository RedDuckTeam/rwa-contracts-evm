// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @dev OpenZeppelin's TimelockController, unmodified, under a name this repository owns.
///      Hardhat emits artifacts only for contracts declared inside the project, and the
///      deploy script must instantiate this one.
///
///      There is deliberately no logic, and none should be added. Two properties depend on
///      that emptiness: the timelock is NOT upgradeable (it is what every other upgrade
///      passes through), and it keeps its own internal AccessControl — the single documented
///      exception to "one registry holds all privileges". See docs/TRUST-MODEL.md.
contract RwaTimelockController is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
