// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {Roles} from "../access/Roles.sol";
import {OperationPausable} from "../pause/OperationPausable.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {IERC7943} from "../interfaces/IERC7943.sol";

/// @dev Non-rebasing NAV token: ERC-20 + ERC-2612 + ERC-165 + ERC-7943. Abstract on purpose;
///      a fork ships a thin subclass fixing name and symbol and edits nothing here.
///
///      ## The privileged refund path
///
///      Fail-closed on entry is prudent; fail-closed on exit is confiscation by accident. A
///      user cancelling a redemption while transfers are paused, or after being blacklisted,
///      would otherwise have their escrow stranded in the vault. {refundFromVault} is the
///      carve-out, and not a general bypass: REFUND_VAULT_ROLE is critical and held solely by
///      the RedemptionVault, sanctions are still enforced, and it authorises exactly ONE
///      transfer of the (from, to, amount) triple it names.
///
///      The ticket lives in EIP-1153 transient storage, which is scoped to the TRANSACTION,
///      not the call frame — there is no frame-scoped variant. Consuming it in `_update` is
///      what makes it one-shot: a second transfer in the same transaction finds an empty slot
///      and meets the full gate set. `test_RevertWhen_RefundIsFollowedByAnOrdinaryTransfer
///      InTheSameTx` guards this and is load-bearing.
///
///      Enforcement transfers use the same mechanism with a different tag: ERC-7943 permits
///      `forcedTransfer` to bypass `canTransfer`, since seizing from a blacklisted or
///      sanctioned account is its entire purpose.
abstract contract RwaToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    OperationPausable,
    UUPSUpgradeable,
    IERC7943
{
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;

    /// @custom:storage-location erc7201:rwa.storage.RwaToken
    struct RwaTokenStorage {
        IComplianceRegistry complianceRegistry;
        mapping(address account => uint256 amount) frozen;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.RwaToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RWA_TOKEN_STORAGE_LOCATION =
        0x59cf01b2735e149da6999d77c31dee32ec72e5a5f4ef92a24a7275695ef52300;

    // keccak256("rwa.transient.RwaToken.privilegedTicket")
    bytes32 private constant PRIVILEGED_TICKET_SLOT =
        0xd521332895850bdd38cf5da1d4c6a1a53270bbb454bd7e6a3d4049860d6f6c7e;

    uint256 private constant TICKET_KIND_REFUND = 1;
    uint256 private constant TICKET_KIND_FORCED = 2;

    event RefundFromVault(address indexed vault, address indexed to, uint256 amount);

    event ComplianceRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);

    error TransfersPaused();

    error ZeroComplianceRegistry();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param name_ A parameter rather than a constant so this contract never needs editing
    ///        during a fork.
    // solhint-disable-next-line func-name-mixedcase
    function __RwaToken_init(
        string memory name_,
        string memory symbol_,
        address registry,
        address complianceRegistry_,
        bool startPaused
    ) internal onlyInitializing {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __WithAccessRegistry_init(registry);

        _setComplianceRegistry(complianceRegistry_);
        __OperationPausable_init(startPaused);
    }

    /// @inheritdoc OperationPausable
    function supportedOperations() public pure override returns (bytes32[] memory ops) {
        ops = new bytes32[](1);
        ops[0] = Roles.OP_TRANSFER;
    }

    /// @dev A multi-product fork MUST namespace this and the two below, or product A's vaults
    ///      hold live privileges over product B's token.
    function minterRole() public view virtual returns (bytes32) {
        return Roles.MINTER_ROLE;
    }

    function burnerRole() public view virtual returns (bytes32) {
        return Roles.BURNER_ROLE;
    }

    function refundVaultRole() public view virtual returns (bytes32) {
        return Roles.REFUND_VAULT_ROLE;
    }

    /// @dev Granted to nobody at deployment.
    function enforcerRole() public view virtual returns (bytes32) {
        return Roles.ENFORCER_ROLE;
    }

    function mint(address to, uint256 amount) external onlyRegistryRole(minterRole()) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRegistryRole(burnerRole()) {
        _burn(from, amount);
    }

    function refundFromVault(
        address to,
        uint256 amount
    ) external onlyRegistryRole(refundVaultRole()) returns (bool) {
        _issueTicket(TICKET_KIND_REFUND, msg.sender, to, amount);
        _transfer(msg.sender, to, amount);
        // Belt and braces: `_update` already consumed the ticket. Clearing again keeps the
        // slot empty even if a future refactor changed the path between here and there.
        _clearTicket(msg.sender, to, amount);

        emit RefundFromVault(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc IERC7943
    /// @dev Per the EIP, frozen tokens are released and `Frozen` emitted BEFORE `Transfer`.
    function forcedTransfer(
        address from,
        address to,
        uint256 amount
    ) external onlyRegistryRole(enforcerRole()) returns (bool) {
        RwaTokenStorage storage $ = _rwaTokenStorage();

        uint256 frozenAmount = $.frozen[from];
        uint256 balance = balanceOf(from);
        uint256 unfrozen = balance > frozenAmount ? balance - frozenAmount : 0;

        if (amount > unfrozen) {
            // `amount <= balance` is enforced by the transfer itself, so this cannot underflow.
            uint256 remainingFrozen = balance - amount;
            $.frozen[from] = remainingFrozen;
            emit Frozen(from, remainingFrozen);
        }

        _issueTicket(TICKET_KIND_FORCED, from, to, amount);
        _transfer(from, to, amount);
        _clearTicket(from, to, amount);

        emit ForcedTransfer(from, to, amount);
        return true;
    }

    /// @inheritdoc IERC7943
    /// @dev The EIP requires freezing more than the held balance to be permitted, so there is
    ///      deliberately no check against `balanceOf`.
    function setFrozenTokens(
        address account,
        uint256 amount
    ) external onlyRegistryRole(enforcerRole()) returns (bool) {
        _rwaTokenStorage().frozen[account] = amount;
        emit Frozen(account, amount);
        return true;
    }

    /// @inheritdoc IERC7943
    function getFrozenTokens(address account) public view returns (uint256) {
        return _rwaTokenStorage().frozen[account];
    }

    /// @inheritdoc IERC7943
    /// @dev Includes the OP_TRANSFER pause, so the answer is a property of the current block
    ///      and must not be cached. A paused token still permits {refundFromVault}, so `false`
    ///      here does not imply every outbound movement is blocked.
    function canSend(address account) public view returns (bool) {
        return !isOperationPaused(Roles.OP_TRANSFER) && _isPartyAllowed(account);
    }

    /// @inheritdoc IERC7943
    function canReceive(address account) public view returns (bool) {
        return !isOperationPaused(Roles.OP_TRANSFER) && _isPartyAllowed(account);
    }

    /// @inheritdoc IERC7943
    function canTransfer(address from, address to, uint256 amount) public view returns (bool) {
        if (!canSend(from) || !canReceive(to)) return false;

        uint256 balance = balanceOf(from);
        uint256 frozenAmount = getFrozenTokens(from);
        uint256 unfrozen = balance > frozenAmount ? balance - frozenAmount : 0;
        return amount <= unfrozen;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return
            interfaceId == type(IERC7943).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function complianceRegistry() public view returns (IComplianceRegistry) {
        return _rwaTokenStorage().complianceRegistry;
    }

    /// @dev Timelocked: swaps the whole rulebook in one transaction.
    function setComplianceRegistry(address newRegistry) external onlyRegistryRole(criticalConfigRole()) {
        _setComplianceRegistry(newRegistry);
    }

    /// @dev Fixed at 18. NAV is quoted in WAD throughout the platform.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @dev The single choke point for every balance change — transfers, mints and burns —
    ///      so no path can skip the gates by accident. `_consumeTicket` runs FIRST, before any
    ///      external compliance call, so a hostile registry re-entering finds an empty slot.
    function _update(address from, address to, uint256 value) internal override {
        uint256 ticketKind = _consumeTicket(from, to, value);

        if (ticketKind == TICKET_KIND_FORCED) {
            // Enforcement is absolute, and the frozen amount was already released.
            super._update(from, to, value);
            return;
        }

        IComplianceRegistry registry_ = _rwaTokenStorage().complianceRegistry;

        if (from == address(0)) {
            // Mint. Defence in depth: the vault already ran its own greenlist check, but the
            // token refuses to create supply for a blocked party regardless.
            registry_.checkParty(to);
        } else {
            if (ticketKind == TICKET_KIND_REFUND) {
                // Neither the pause nor the blacklist may trap a user's own money on the way
                // out. Sanctions still apply, and an unreachable oracle still fails closed.
                registry_.checkNotSanctioned(from);
                registry_.checkNotSanctioned(to);
            } else if (to == address(0)) {
                // Burn. Only the holder is a party; there is no recipient to vet.
                registry_.checkParty(from);
            } else {
                if (isOperationPaused(Roles.OP_TRANSFER)) revert TransfersPaused();
                registry_.checkTransfer(from, to);
            }

            _requireUnfrozen(from, value);
        }

        super._update(from, to, value);
    }

    function _setComplianceRegistry(address newRegistry) private {
        if (newRegistry == address(0)) revert ZeroComplianceRegistry();

        RwaTokenStorage storage $ = _rwaTokenStorage();
        emit ComplianceRegistryUpdated(address($.complianceRegistry), newRegistry);
        $.complianceRegistry = IComplianceRegistry(newRegistry);
    }

    function _isPartyAllowed(address account) private view returns (bool) {
        return _rwaTokenStorage().complianceRegistry.isPartyAllowed(account);
    }

    /// @dev Frozen tokens are unavailable to every ordinary path, including burns.
    ///      {forcedTransfer} releases what it needs before reaching here.
    function _requireUnfrozen(address from, uint256 value) private view {
        uint256 frozenAmount = _rwaTokenStorage().frozen[from];
        if (frozenAmount == 0) return;

        uint256 balance = balanceOf(from);
        uint256 unfrozen = balance > frozenAmount ? balance - frozenAmount : 0;
        if (value > unfrozen) {
            revert ERC7943InsufficientUnfrozenBalance(from, value, unfrozen);
        }
    }

    function _issueTicket(uint256 kind, address from, address to, uint256 value) private {
        _ticketSlot(from, to, value).tstore(kind);
    }

    /// @dev Returns the ticket kind and CLEARS the slot, making the grant single-use.
    ///
    ///      The slot is DERIVED from the triple rather than holding a hash `_update` compares
    ///      against. Both shapes reject a mismatched transfer, but the derived slot rejects it
    ///      structurally: a different triple simply reads a different, empty slot. The
    ///      comparison shape needed a "live ticket, no match" branch no call path could reach,
    ///      and unreachable code guarding a security property is worse than none — nothing can
    ///      prove it still works.
    function _consumeTicket(address from, address to, uint256 value) private returns (uint256 kind) {
        TransientSlot.Uint256Slot slot = _ticketSlot(from, to, value);
        kind = slot.tload();
        if (kind != 0) slot.tstore(0);
    }

    function _clearTicket(address from, address to, uint256 value) private {
        _ticketSlot(from, to, value).tstore(0);
    }

    function _ticketSlot(
        address from,
        address to,
        uint256 value
    ) private pure returns (TransientSlot.Uint256Slot) {
        return keccak256(abi.encode(PRIVILEGED_TICKET_SLOT, from, to, value)).asUint256();
    }

    function _rwaTokenStorage() private pure returns (RwaTokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := RWA_TOKEN_STORAGE_LOCATION
        }
    }

    function _authorizeUpgrade(address) internal override onlyRegistryRole(upgraderRole()) {}
}
