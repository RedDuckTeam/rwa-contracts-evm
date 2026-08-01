// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

/// @dev Enumeration is part of the interface, not an extra: deployment verification has to
///      assert negative facts ("only the RedemptionVault holds REFUND_VAULT_ROLE"), which
///      `hasRole` cannot express.
interface IAccessRegistry is IAccessControlEnumerable {
    function isCriticalRole(bytes32 role) external view returns (bool);
}
