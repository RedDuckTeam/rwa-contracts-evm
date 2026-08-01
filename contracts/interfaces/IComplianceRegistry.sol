// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Two families with opposite failure behaviour. `check*` reverts on any uncertainty,
///      including an unreachable sanctions oracle, and belongs on money paths. `is*Allowed`
///      returns false on that same uncertainty, and belongs on view paths — above all the
///      ERC-7943 predicates, which the EIP forbids from reverting. They diverge only when
///      the oracle misbehaves.
interface IComplianceRegistry {
    function isBlacklisted(address account) external view returns (bool);

    /// @dev Gates vault operations only; transfers between holders are free.
    function isGreenlisted(address account) external view returns (bool);

    function greenlistEnabled() external view returns (bool);

    function sanctionsOracle() external view returns (address);

    /// @dev Returns false when the oracle is unreachable — the opposite of fail-closed, and
    ///      deliberate. Its only caller is the vault sweep guard, where "not proven
    ///      sanctioned" must mean "do not confiscate". Money paths want {checkNotSanctioned}.
    function isSanctioned(address account) external view returns (bool);

    function isPartyAllowed(address account) external view returns (bool);

    function isVaultOpAllowed(address user) external view returns (bool);

    function checkParty(address account) external view;

    /// @dev The one check that survives the refund carve-out: blacklisting is a domestic
    ///      control that must not strand a user's own funds, a sanctions hit is not.
    function checkNotSanctioned(address account) external view;

    function checkTransfer(address from, address to) external view;

    function checkVaultOp(address user) external view;
}
