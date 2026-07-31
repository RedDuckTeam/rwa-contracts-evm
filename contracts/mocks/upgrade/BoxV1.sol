// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @dev Carries the same ERC-7201 storage convention as the production contracts, so the
///      upgrade-safety validation it proves is the validation the real contracts get.
contract BoxV1 is Initializable, UUPSUpgradeable {
    /// @custom:storage-location erc7201:rwa.storage.Box
    struct BoxStorage {
        uint256 value;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.Box")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BOX_STORAGE_LOCATION =
        0x0c4cc09388ced31846d0ecd458eb6d74f50f82725246d4e2950105425e826500;

    address public upgrader;

    error NotUpgrader();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 initialValue, address upgrader_) external initializer {
        _boxStorage().value = initialValue;
        upgrader = upgrader_;
    }

    function value() external view returns (uint256) {
        return _boxStorage().value;
    }

    function setValue(uint256 newValue) external {
        _boxStorage().value = newValue;
    }

    function _boxStorage() internal pure returns (BoxStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BOX_STORAGE_LOCATION
        }
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != upgrader) revert NotUpgrader();
    }
}
