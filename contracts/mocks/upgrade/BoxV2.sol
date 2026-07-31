// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {BoxV1} from "./BoxV1.sol";

/// @dev The positive half of the upgrade-safety proof: appends state, touches nothing existing,
///      and must be accepted.
contract BoxV2 is BoxV1 {
    /// @custom:storage-location erc7201:rwa.storage.BoxV2
    struct BoxV2Storage {
        uint256 extra;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.BoxV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BOX_V2_STORAGE_LOCATION =
        0x567a757d61da32f39ed4d621de1deb066ab2d851c54ed4426f1cbe2a96dabb00;

    function initializeV2(uint256 extra_) external reinitializer(2) {
        _boxV2Storage().extra = extra_;
    }

    function extra() external view returns (uint256) {
        return _boxV2Storage().extra;
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function _boxV2Storage() internal pure returns (BoxV2Storage storage $) {
        assembly ("memory-safe") {
            $.slot := BOX_V2_STORAGE_LOCATION
        }
    }
}
