// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Roles} from "../access/Roles.sol";
import {WithAccessRegistry} from "../access/WithAccessRegistry.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {ISanctionsList} from "../interfaces/ISanctionsList.sol";

/// @dev Consumers hold a pointer that CRITICAL_CONFIG_ROLE can re-point through the timelock:
///      that is the extension seam for a fork with different compliance rules, and swapping
///      the rulebook still costs a full delay.
contract ComplianceRegistry is Initializable, WithAccessRegistry, UUPSUpgradeable, IComplianceRegistry {
    /// @custom:storage-location erc7201:rwa.storage.ComplianceRegistry
    struct ComplianceRegistryStorage {
        mapping(address account => bool blacklisted) blacklisted;
        mapping(address account => bool greenlisted) greenlisted;
        bool greenlistEnabled;
        ISanctionsList sanctionsOracle;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.ComplianceRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant COMPLIANCE_REGISTRY_STORAGE_LOCATION =
        0x99f36c048382437f4af984137db7c0292e7a488da2994ae374f9aa017ed4e400;

    /// @dev Generous for a mapping read, and hard-bounded so a hostile or buggy oracle on the
    ///      hot path of every transfer cannot consume the caller's whole budget.
    uint256 public constant SANCTIONS_ORACLE_GAS_LIMIT = 100_000;

    event BlacklistUpdated(address indexed account, bool blacklisted);
    event GreenlistUpdated(address indexed account, bool greenlisted);
    event GreenlistEnabledUpdated(bool enabled);
    event SanctionsOracleUpdated(address indexed previousOracle, address indexed newOracle);

    error BlacklistedAccount(address account);

    error SanctionedAccount(address account);

    error NotGreenlisted(address account);

    error SanctionsOracleUnavailable(address account);

    error SelfUnblacklistForbidden(address account);

    error StatusUnchanged();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param sanctionsOracle_ Chainalysis-compatible oracle, or zero to disable the gate.
    function initialize(
        address registry,
        address sanctionsOracle_,
        bool greenlistEnabled_
    ) external initializer {
        __WithAccessRegistry_init(registry);

        ComplianceRegistryStorage storage $ = _complianceRegistryStorage();
        $.sanctionsOracle = ISanctionsList(sanctionsOracle_);
        $.greenlistEnabled = greenlistEnabled_;

        emit SanctionsOracleUpdated(address(0), sanctionsOracle_);
        emit GreenlistEnabledUpdated(greenlistEnabled_);
    }

    function complianceAdminRole() public view virtual returns (bytes32) {
        return Roles.COMPLIANCE_ADMIN_ROLE;
    }

    function greenlistOperatorRole() public view virtual returns (bytes32) {
        return Roles.GREENLIST_OPERATOR_ROLE;
    }

    function blacklistOperatorRole() public view virtual returns (bytes32) {
        return Roles.BLACKLIST_OPERATOR_ROLE;
    }

    /// @dev The blacklist is a mapping rather than a role because AccessControl roles are
    ///      always self-renounceable. Clearing your own entry is refused for the same reason:
    ///      an operator who is later blacklisted could otherwise simply undo it.
    function setBlacklisted(
        address account,
        bool blacklisted
    ) external onlyRegistryRole(blacklistOperatorRole()) {
        if (!blacklisted && account == msg.sender) revert SelfUnblacklistForbidden(account);

        ComplianceRegistryStorage storage $ = _complianceRegistryStorage();
        if ($.blacklisted[account] == blacklisted) revert StatusUnchanged();

        $.blacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }

    function setGreenlisted(
        address account,
        bool greenlisted
    ) external onlyRegistryRole(greenlistOperatorRole()) {
        ComplianceRegistryStorage storage $ = _complianceRegistryStorage();
        if ($.greenlisted[account] == greenlisted) revert StatusUnchanged();

        $.greenlisted[account] = greenlisted;
        emit GreenlistUpdated(account, greenlisted);
    }

    function setGreenlistEnabled(bool enabled) external onlyRegistryRole(complianceAdminRole()) {
        ComplianceRegistryStorage storage $ = _complianceRegistryStorage();
        if ($.greenlistEnabled == enabled) revert StatusUnchanged();

        $.greenlistEnabled = enabled;
        emit GreenlistEnabledUpdated(enabled);
    }

    /// @dev Timelocked: a failed oracle therefore stops money paths until a replacement
    ///      matures, accepted knowingly because serving a sanctioned party is worse.
    function setSanctionsOracle(address newOracle) external onlyRegistryRole(criticalConfigRole()) {
        ComplianceRegistryStorage storage $ = _complianceRegistryStorage();
        address previous = address($.sanctionsOracle);
        if (previous == newOracle) revert StatusUnchanged();

        $.sanctionsOracle = ISanctionsList(newOracle);
        emit SanctionsOracleUpdated(previous, newOracle);
    }

    /// @inheritdoc IComplianceRegistry
    function isBlacklisted(address account) public view returns (bool) {
        return _complianceRegistryStorage().blacklisted[account];
    }

    /// @inheritdoc IComplianceRegistry
    function isGreenlisted(address account) public view returns (bool) {
        return _complianceRegistryStorage().greenlisted[account];
    }

    /// @inheritdoc IComplianceRegistry
    function greenlistEnabled() public view returns (bool) {
        return _complianceRegistryStorage().greenlistEnabled;
    }

    /// @inheritdoc IComplianceRegistry
    function sanctionsOracle() public view returns (address) {
        return address(_complianceRegistryStorage().sanctionsOracle);
    }

    /// @inheritdoc IComplianceRegistry
    function isSanctioned(address account) public view returns (bool) {
        (bool sanctioned, bool oracleAnswered) = _querySanctions(account);
        return oracleAnswered && sanctioned;
    }

    /// @inheritdoc IComplianceRegistry
    function isPartyAllowed(address account) public view returns (bool) {
        if (isBlacklisted(account)) return false;

        (bool sanctioned, bool oracleAnswered) = _querySanctions(account);
        return oracleAnswered && !sanctioned;
    }

    /// @inheritdoc IComplianceRegistry
    function isVaultOpAllowed(address user) public view returns (bool) {
        if (!isPartyAllowed(user)) return false;
        return !greenlistEnabled() || isGreenlisted(user);
    }

    /// @inheritdoc IComplianceRegistry
    function checkParty(address account) public view {
        _checkParty(account);
    }

    /// @inheritdoc IComplianceRegistry
    function checkNotSanctioned(address account) public view {
        (bool sanctioned, bool oracleAnswered) = _querySanctions(account);
        if (!oracleAnswered) revert SanctionsOracleUnavailable(account);
        if (sanctioned) revert SanctionedAccount(account);
    }

    /// @inheritdoc IComplianceRegistry
    function checkTransfer(address from, address to) external view {
        _checkParty(from);
        _checkParty(to);
    }

    /// @inheritdoc IComplianceRegistry
    function checkVaultOp(address user) external view {
        _checkParty(user);
        if (greenlistEnabled() && !isGreenlisted(user)) revert NotGreenlisted(user);
    }

    function _checkParty(address account) private view {
        if (isBlacklisted(account)) revert BlacklistedAccount(account);

        (bool sanctioned, bool oracleAnswered) = _querySanctions(account);
        if (!oracleAnswered) revert SanctionsOracleUnavailable(account);
        if (sanctioned) revert SanctionedAccount(account);
    }

    /// @return sanctioned Meaningful only when `oracleAnswered`.
    /// @return oracleAnswered False on revert, exhausted stipend, or a return other than one
    ///         word. A non-contract address lands here too: staticcall to an address with no
    ///         code succeeds with empty return data, which would decode as "not sanctioned".
    function _querySanctions(address account) private view returns (bool sanctioned, bool oracleAnswered) {
        ISanctionsList oracle = _complianceRegistryStorage().sanctionsOracle;
        if (address(oracle) == address(0)) return (false, true);

        (bool success, bytes memory result) = address(oracle).staticcall{gas: SANCTIONS_ORACLE_GAS_LIMIT}(
            abi.encodeCall(ISanctionsList.isSanctioned, (account))
        );
        if (!success || result.length != 32) return (false, false);

        return (abi.decode(result, (bool)), true);
    }

    function _complianceRegistryStorage() private pure returns (ComplianceRegistryStorage storage $) {
        assembly ("memory-safe") {
            $.slot := COMPLIANCE_REGISTRY_STORAGE_LOCATION
        }
    }

    function _authorizeUpgrade(address) internal override onlyRegistryRole(upgraderRole()) {}
}
