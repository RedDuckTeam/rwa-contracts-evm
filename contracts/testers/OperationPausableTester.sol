// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Roles} from "../access/Roles.sol";
import {OperationPausable} from "../pause/OperationPausable.sol";

/// @dev Gates two unrelated opIds so tests can prove the switches are independent.
contract OperationPausableTester is Initializable, OperationPausable, UUPSUpgradeable {
    uint256 public depositCount;
    uint256 public redeemCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address registry, bool startPaused) external initializer {
        __WithAccessRegistry_init(registry);
        __OperationPausable_init(startPaused);
    }

    function supportedOperations() public pure override returns (bytes32[] memory ops) {
        ops = new bytes32[](2);
        ops[0] = Roles.OP_DEPOSIT_INSTANT;
        ops[1] = Roles.OP_REDEEM_INSTANT;
    }

    function doDeposit() external whenOperationNotPaused(Roles.OP_DEPOSIT_INSTANT) {
        ++depositCount;
    }

    function doRedeem() external whenOperationNotPaused(Roles.OP_REDEEM_INSTANT) {
        ++redeemCount;
    }

    function hasRoleView(bytes32 role, address account) external view returns (bool) {
        return _hasRegistryRole(role, account);
    }

    function requireRole(bytes32 role, address account) external view {
        _checkRegistryRole(role, account);
    }

    function _authorizeUpgrade(address) internal override onlyRegistryRole(upgraderRole()) {}
}
