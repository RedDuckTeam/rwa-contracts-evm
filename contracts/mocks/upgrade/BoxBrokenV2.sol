// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @dev {BoxV1} declares `address upgrader` in slot 0; this one inserts `uint256 injected` ahead
///      of it, shifting every subsequent variable. The validator must reject it — that rejection
///      is the negative half of the proof, so never "fix" this contract.
contract BoxBrokenV2 is Initializable, UUPSUpgradeable {
    uint256 public injected;
    address public upgrader;

    error NotUpgrader();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 initialValue, address upgrader_) external initializer {
        injected = initialValue;
        upgrader = upgrader_;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != upgrader) revert NotUpgrader();
    }
}
