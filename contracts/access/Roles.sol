// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

/// @dev Contracts read these through the virtual getters on {WithAccessRegistry}, not
///      directly: a fork sharing one registry across products must namespace MINTER,
///      BURNER and REFUND_VAULT per product.
library Roles {
    // Critical tier: roleAdmin is TIMELOCK_ADMIN_ROLE, non-renounceable.
    bytes32 internal constant TIMELOCK_ADMIN_ROLE = keccak256("rwa.role.TIMELOCK_ADMIN");
    bytes32 internal constant UPGRADER_ROLE = keccak256("rwa.role.UPGRADER");
    bytes32 internal constant CRITICAL_CONFIG_ROLE = keccak256("rwa.role.CRITICAL_CONFIG");
    bytes32 internal constant REFUND_VAULT_ROLE = keccak256("rwa.role.REFUND_VAULT");
    bytes32 internal constant ENFORCER_ROLE = keccak256("rwa.role.ENFORCER");

    // Operational tier: roleAdmin is DEFAULT_ADMIN_ROLE.
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("rwa.role.COMPLIANCE_ADMIN");
    bytes32 internal constant GREENLIST_OPERATOR_ROLE = keccak256("rwa.role.GREENLIST_OPERATOR");
    bytes32 internal constant BLACKLIST_OPERATOR_ROLE = keccak256("rwa.role.BLACKLIST_OPERATOR");
    bytes32 internal constant REQUEST_OPERATOR_ROLE = keccak256("rwa.role.REQUEST_OPERATOR");
    bytes32 internal constant VAULT_ADMIN_ROLE = keccak256("rwa.role.VAULT_ADMIN");
    bytes32 internal constant FEED_OPERATOR_ROLE = keccak256("rwa.role.FEED_OPERATOR");
    bytes32 internal constant FEED_ADMIN_ROLE = keccak256("rwa.role.FEED_ADMIN");
    bytes32 internal constant PAUSER_ROLE = keccak256("rwa.role.PAUSER");
    bytes32 internal constant UNPAUSER_ROLE = keccak256("rwa.role.UNPAUSER");
    bytes32 internal constant MINTER_ROLE = keccak256("rwa.role.MINTER");
    bytes32 internal constant BURNER_ROLE = keccak256("rwa.role.BURNER");

    // Pausable operation ids.
    bytes32 internal constant OP_DEPOSIT_INSTANT = keccak256("rwa.op.DEPOSIT_INSTANT");
    bytes32 internal constant OP_DEPOSIT_REQUEST = keccak256("rwa.op.DEPOSIT_REQUEST");
    bytes32 internal constant OP_REDEEM_INSTANT = keccak256("rwa.op.REDEEM_INSTANT");
    bytes32 internal constant OP_REDEEM_REQUEST = keccak256("rwa.op.REDEEM_REQUEST");
    bytes32 internal constant OP_TRANSFER = keccak256("rwa.op.TRANSFER");
    bytes32 internal constant OP_ORACLE_UPDATE = keccak256("rwa.op.ORACLE_UPDATE");
}
