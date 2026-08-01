// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Roles} from "../access/Roles.sol";
import {OperationPausable} from "../pause/OperationPausable.sol";
import {DecimalsConverter} from "../libraries/DecimalsConverter.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {IDataFeed} from "../interfaces/IDataFeed.sol";
import {IRwaToken} from "../interfaces/IRwaToken.sol";

/// @dev Shared machinery for both vaults: the payment-token registry, the parameter set and
///      its caps, the treasury flow, and the request state machine.
///
///      ## Parameters are bounded twice
///
///      VAULT_ADMIN_ROLE tunes fees, limits and minimums without a timelock, but every one is
///      clamped by a constant only an upgrade can change. Addresses that decide where money
///      lands are not in that set at all — they are CRITICAL_CONFIG_ROLE.
///
///      ## Money never rests here
///
///      Instant flows pull the payment token in, measure the ACTUAL delta, and forward it the
///      same transaction. Only request escrow stays, and only until the request resolves.
///
///      ## The blocked-refund problem
///
///      Cancel and reject are exits, so they must not be gated by the transfer pause, the
///      blacklist, or a price. The token's `refundFromVault` carve-out handles the first two.
///      What neither can handle is the PAYMENT TOKEN refusing the transfer — USDC and USDT run
///      their own blacklists, entirely outside this system.
///
///      Then the exit is recorded as attempted ({RefundBlocked}), the request stays `Pending`,
///      and it becomes eligible for {sweepBlockedRefund}. The user may simply cancel again
///      later. The sweep RETRIES the refund at execution time rather than trusting the stale
///      flag, so a holder unblocked during the 48h delay still gets paid: it heals rather than
///      confiscates. Only a retry that fails again produces terminal `Swept`.
abstract contract ManageableVault is
    Initializable,
    OperationPausable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    enum RequestStatus {
        None,
        Pending,
        Approved,
        Rejected,
        Cancelled,
        Swept
    }

    /// @param enabled Disabling never traps existing escrow: reject and cancel keep working.
    /// @param remainingAllowanceWad Budget in WAD, decremented per use. `type(uint256).max`
    ///        means unlimited.
    struct TokenConfig {
        bool registered;
        bool enabled;
        uint8 decimals;
        uint256 feeBps;
        uint256 remainingAllowanceWad;
    }

    /// @dev Field names follow the ERC-7540 vocabulary so a compatibility facade can be added
    ///      later without renaming state. The fee and decimals are PINNED at submission:
    ///      resolving against today's parameters would let an operator change the economics of
    ///      a request after the user committed to it.
    ///
    ///      Field ORDER is load-bearing. `owner`, `decimalsPinned`, `status` and
    ///      `refundBlocked` total 23 bytes and share one slot; declared apart they would
    ///      occupy four, and every submitted request pays that difference.
    struct Request {
        address owner;
        uint8 decimalsPinned;
        RequestStatus status;
        bool refundBlocked;
        address paymentToken;
        uint256 amountWad;
        uint256 feeBpsPinned;
        /// @dev Units differ BY SIDE: WAD for a deposit, the payment token's own units for a
        ///      redemption. Each vault reads only its own requests, so this is unambiguous
        ///      today — but any cross-side reader must branch on which vault it is reading.
        uint256 minOutWad;
        uint256 submittedAt;
    }

    /// @dev A struct rather than a flat argument list because thirteen stack slots exhaust the
    ///      EVM's reachable depth. Field order is chosen for readability, not packing: this is
    ///      only ever passed in calldata, so slot layout costs nothing.
    // solhint-disable-next-line gas-struct-packing
    struct VaultInitParams {
        address registry;
        address rwaToken;
        address dataFeed;
        address complianceRegistry;
        address tokensReceiver;
        address feeReceiver;
        address blockedFundsReceiver;
        uint256 instantFeeBps;
        uint256 instantDailyLimitWad;
        uint256 minAmountWad;
        uint256 minFirstAmountWad;
        uint256 variationToleranceBps;
        bool startPaused;
    }

    /// @custom:storage-location erc7201:rwa.storage.ManageableVault
    struct ManageableVaultStorage {
        IRwaToken rwaToken;
        IDataFeed dataFeed;
        IComplianceRegistry complianceRegistry;
        address tokensReceiver;
        address feeReceiver;
        address blockedFundsReceiver;
        uint256 instantFeeBps;
        uint256 instantDailyLimitWad;
        uint256 minAmountWad;
        uint256 minFirstAmountWad;
        uint256 variationToleranceBps;
        uint256 nextRequestId;
        mapping(address token => TokenConfig config) tokensConfig;
        address[] paymentTokens;
        mapping(address account => bool waived) feeWaived;
        mapping(address account => bool waived) minAmountWaived;
        mapping(uint256 utcDay => uint256 spentWad) dailySpentWad;
        mapping(uint256 requestId => Request request) requests;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.ManageableVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MANAGEABLE_VAULT_STORAGE_LOCATION =
        0xb88f4ce5b84c96e1b47983a9a0399fe962af6d40585346b605758f03e5f4d900;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant WAD = 1e18;

    uint256 public constant MAX_INSTANT_FEE_BPS = 500;

    uint256 public constant MAX_TOKEN_FEE_BPS = 500;

    uint256 public constant MAX_VARIATION_TOLERANCE_BPS = 1_000;

    /// @dev Comfortably above a worst-case ERC-20 transfer, so a failure genuinely means the
    ///      token refused rather than that the caller was stingy. See {_tryRefund}.
    uint256 public constant MIN_REFUND_GAS = 150_000;

    /// @dev Bounds the opposite abuse from a fee: a minimum set absurdly high would lock every
    ///      retail user out of the product.
    uint256 public constant MAX_MIN_AMOUNT_WAD = 100_000e18;

    event PaymentTokenAdded(address indexed token, uint8 decimals, uint256 feeBps, uint256 allowanceWad);
    event PaymentTokenUpdated(address indexed token, bool enabled, uint256 feeBps, uint256 allowanceWad);
    event InstantFeeUpdated(uint256 previousBps, uint256 newBps);
    event InstantDailyLimitUpdated(uint256 previousLimitWad, uint256 newLimitWad);
    event MinAmountsUpdated(uint256 minAmountWad, uint256 minFirstAmountWad);
    event VariationToleranceUpdated(uint256 previousBps, uint256 newBps);
    event FeeWaiverUpdated(address indexed account, bool waived);
    event MinAmountWaiverUpdated(address indexed account, bool waived);
    event ReceiversUpdated(address tokensReceiver, address feeReceiver, address blockedFundsReceiver);
    event DataFeedUpdated(address indexed previousFeed, address indexed newFeed);
    event ComplianceRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);

    event RequestSubmitted(
        uint256 indexed requestId,
        address indexed owner,
        address indexed paymentToken,
        uint256 amountWad,
        uint256 minOutWad
    );
    event RequestApproved(uint256 indexed requestId, uint256 operatorRateWad, uint256 oracleRateWad, uint256 outWad);
    event RequestRejected(uint256 indexed requestId);
    event RequestCancelled(uint256 indexed requestId);

    /// @dev The one outcome that completes successfully WITHOUT moving money. Monitoring must
    ///      treat it as an alert, not a normal completion.
    event RefundBlocked(uint256 indexed requestId, address indexed owner, address indexed token);

    event RefundRecovered(uint256 indexed requestId, address indexed owner, uint256 amountWad);

    /// @dev Escrow diverted to `blockedFundsReceiver`. Irreversible.
    event EscrowSwept(uint256 indexed requestId, address indexed owner, uint256 amountWad);

    error TokenNotConfigured(address token);
    error TokenAlreadyConfigured(address token);
    error TokenDisabled(address token);
    error TokenAllowanceExceeded(address token, uint256 requestedWad, uint256 remainingWad);
    error AmountBelowMinimum(uint256 amountWad, uint256 minimumWad);
    error DailyLimitExceeded(uint256 requestedWad, uint256 remainingWad);
    error SlippageExceeded(uint256 outWad, uint256 minOutWad);
    error RateOutsideTolerance(uint256 operatorRateWad, uint256 oracleRateWad, uint256 toleranceBps);
    error RequestNotPending(uint256 requestId);
    error NotRequestOwner(uint256 requestId, address caller);
    error NothingToSweep(uint256 requestId);
    error ConfigOutOfRange();
    error ZeroAmount();
    error OnlySelf();

    error UnsupportedTokenDecimals(address token);

    /// @dev A refund attempt ran out of gas rather than being refused.
    error RefundGasExhausted(uint256 requestId);

    modifier onlyCompliantCaller() {
        _vaultStorage().complianceRegistry.checkVaultOp(msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // solhint-disable-next-line func-name-mixedcase
    function __ManageableVault_init(VaultInitParams calldata params) internal onlyInitializing {
        __WithAccessRegistry_init(params.registry);

        ManageableVaultStorage storage $ = _vaultStorage();
        if (
            params.rwaToken == address(0) ||
            params.dataFeed == address(0) ||
            params.complianceRegistry == address(0)
        ) {
            revert ConfigOutOfRange();
        }

        $.rwaToken = IRwaToken(params.rwaToken);
        $.dataFeed = IDataFeed(params.dataFeed);
        $.complianceRegistry = IComplianceRegistry(params.complianceRegistry);
        $.nextRequestId = 1;

        _setReceivers($, params.tokensReceiver, params.feeReceiver, params.blockedFundsReceiver);
        _setInstantFeeBps($, params.instantFeeBps);
        _setInstantDailyLimitWad($, params.instantDailyLimitWad);
        _setMinAmounts($, params.minAmountWad, params.minFirstAmountWad);
        _setVariationToleranceBps($, params.variationToleranceBps);

        __OperationPausable_init(params.startPaused);
    }

    function vaultAdminRole() public view virtual returns (bytes32) {
        return Roles.VAULT_ADMIN_ROLE;
    }

    /// @dev Separate from {vaultAdminRole} on purpose: the account that moves user funds must
    ///      not also be the account that sets the limits those movements are checked against.
    function requestOperatorRole() public view virtual returns (bytes32) {
        return Roles.REQUEST_OPERATOR_ROLE;
    }

    /// @dev Decimals are read once and cached. Above 18 is rejected rather than scaled down,
    ///      which would make the WAD conversion itself lossy.
    function addPaymentToken(
        address token,
        uint256 feeBps,
        uint256 allowanceWad
    ) external onlyRegistryRole(vaultAdminRole()) {
        ManageableVaultStorage storage $ = _vaultStorage();
        if (_isRegistered($, token)) revert TokenAlreadyConfigured(token);
        if (feeBps > MAX_TOKEN_FEE_BPS) revert ConfigOutOfRange();

        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals > DecimalsConverter.WAD_DECIMALS) {
            revert DecimalsConverter.DecimalsTooHigh(tokenDecimals);
        }
        // Not a plausible payment asset, and rejecting it keeps the registry's two views — the
        // mapping and the append-only list — in agreement.
        if (tokenDecimals == 0) revert UnsupportedTokenDecimals(token);

        $.tokensConfig[token] = TokenConfig({
            registered: true,
            enabled: true,
            decimals: tokenDecimals,
            feeBps: feeBps,
            remainingAllowanceWad: allowanceWad
        });
        $.paymentTokens.push(token);

        emit PaymentTokenAdded(token, tokenDecimals, feeBps, allowanceWad);
    }

    /// @dev Disabling only closes NEW business. Reject and cancel keep working on escrow
    ///      already held in a delisted token, so delisting can never strand a user.
    function updatePaymentToken(
        address token,
        bool enabled,
        uint256 feeBps,
        uint256 allowanceWad
    ) external onlyRegistryRole(vaultAdminRole()) {
        ManageableVaultStorage storage $ = _vaultStorage();
        if (!_isRegistered($, token)) revert TokenNotConfigured(token);
        if (feeBps > MAX_TOKEN_FEE_BPS) revert ConfigOutOfRange();

        TokenConfig storage config = $.tokensConfig[token];
        config.enabled = enabled;
        config.feeBps = feeBps;
        config.remainingAllowanceWad = allowanceWad;

        emit PaymentTokenUpdated(token, enabled, feeBps, allowanceWad);
    }

    function paymentTokenConfig(address token) external view returns (TokenConfig memory) {
        return _vaultStorage().tokensConfig[token];
    }

    function paymentTokens() external view returns (address[] memory) {
        return _vaultStorage().paymentTokens;
    }

    function setInstantFeeBps(uint256 newBps) external onlyRegistryRole(vaultAdminRole()) {
        _setInstantFeeBps(_vaultStorage(), newBps);
    }

    function setInstantDailyLimitWad(uint256 newLimitWad) external onlyRegistryRole(vaultAdminRole()) {
        _setInstantDailyLimitWad(_vaultStorage(), newLimitWad);
    }

    function setMinAmounts(
        uint256 newMinAmountWad,
        uint256 newMinFirstAmountWad
    ) external onlyRegistryRole(vaultAdminRole()) {
        _setMinAmounts(_vaultStorage(), newMinAmountWad, newMinFirstAmountWad);
    }

    function setFeeWaiver(address account, bool waived) external onlyRegistryRole(vaultAdminRole()) {
        _vaultStorage().feeWaived[account] = waived;
        emit FeeWaiverUpdated(account, waived);
    }

    function setMinAmountWaiver(address account, bool waived) external onlyRegistryRole(vaultAdminRole()) {
        _vaultStorage().minAmountWaived[account] = waived;
        emit MinAmountWaiverUpdated(account, waived);
    }

    function setReceivers(
        address newTokensReceiver,
        address newFeeReceiver,
        address newBlockedFundsReceiver
    ) external onlyRegistryRole(criticalConfigRole()) {
        _setReceivers(_vaultStorage(), newTokensReceiver, newFeeReceiver, newBlockedFundsReceiver);
    }

    /// @dev A guardrail on the operator, so the operator's own admin cannot widen it.
    function setVariationToleranceBps(uint256 newBps) external onlyRegistryRole(criticalConfigRole()) {
        _setVariationToleranceBps(_vaultStorage(), newBps);
    }

    function setDataFeed(address newDataFeed) external onlyRegistryRole(criticalConfigRole()) {
        if (newDataFeed == address(0)) revert ConfigOutOfRange();
        ManageableVaultStorage storage $ = _vaultStorage();
        emit DataFeedUpdated(address($.dataFeed), newDataFeed);
        $.dataFeed = IDataFeed(newDataFeed);
    }

    function setComplianceRegistry(address newRegistry) external onlyRegistryRole(criticalConfigRole()) {
        if (newRegistry == address(0)) revert ConfigOutOfRange();
        ManageableVaultStorage storage $ = _vaultStorage();
        emit ComplianceRegistryUpdated(address($.complianceRegistry), newRegistry);
        $.complianceRegistry = IComplianceRegistry(newRegistry);
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _vaultStorage().requests[requestId];
    }

    /// @dev Neither paused nor priced. An operator must be able to unwind a request during
    ///      exactly the incident that made the price unusable — that is what closes the free
    ///      option a cancellable, never-expiring request would otherwise create.
    function rejectRequest(uint256 requestId) external nonReentrant onlyRegistryRole(requestOperatorRole()) {
        Request storage request = _pendingRequest(requestId);

        if (_settleRefund(requestId, request)) {
            request.status = RequestStatus.Rejected;
            emit RequestRejected(requestId);
        }
    }

    /// @dev Same carve-outs as {rejectRequest}: no pause, no price.
    function cancelRequest(uint256 requestId) external nonReentrant {
        Request storage request = _pendingRequest(requestId);
        if (request.owner != msg.sender) revert NotRequestOwner(requestId, msg.sender);

        if (_settleRefund(requestId, request)) {
            request.status = RequestStatus.Cancelled;
            emit RequestCancelled(requestId);
        }
    }

    /// @dev Timelocked, and the guard is re-evaluated at EXECUTION time rather than trusted
    ///      from the stale flag. Two ways in: the owner is sanctioned right now, so funds are
    ///      diverted with no retry; or a refund previously failed, in which case it is RETRIED
    ///      here and a now-unblocked owner is paid. Only a retry that fails again produces
    ///      terminal `Swept`; restitution after that is off-chain.
    function sweepBlockedRefund(
        uint256 requestId
    ) external nonReentrant onlyRegistryRole(criticalConfigRole()) {
        ManageableVaultStorage storage $ = _vaultStorage();
        Request storage request = _pendingRequest(requestId);

        bool ownerSanctioned = $.complianceRegistry.isSanctioned(request.owner);

        if (!ownerSanctioned) {
            if (!request.refundBlocked) revert NothingToSweep(requestId);

            if (_tryRefund(requestId)) {
                request.refundBlocked = false;
                request.status = RequestStatus.Cancelled;
                emit RefundRecovered(requestId, request.owner, request.amountWad);
                emit RequestCancelled(requestId);
                return;
            }
        }

        _moveEscrow(request, $.blockedFundsReceiver);
        request.status = RequestStatus.Swept;
        emit EscrowSwept(requestId, request.owner, request.amountWad);
    }

    /// @dev `safeTransfer` reverts rather than returning a flag, and `try/catch` only sees
    ///      EXTERNAL calls — so the refund is routed through `this`. Guarded to self, and
    ///      deliberately not `nonReentrant`, since the guard would reject its own re-entry.
    function performEscrowRefund(uint256 requestId) external {
        if (msg.sender != address(this)) revert OnlySelf();
        Request storage request = _vaultStorage().requests[requestId];
        _moveEscrow(request, request.owner);
    }

    function rwaToken() public view returns (IRwaToken) {
        return _vaultStorage().rwaToken;
    }

    function dataFeed() public view returns (IDataFeed) {
        return _vaultStorage().dataFeed;
    }

    function complianceRegistry() public view returns (IComplianceRegistry) {
        return _vaultStorage().complianceRegistry;
    }

    function tokensReceiver() public view returns (address) {
        return _vaultStorage().tokensReceiver;
    }

    function feeReceiver() public view returns (address) {
        return _vaultStorage().feeReceiver;
    }

    function blockedFundsReceiver() public view returns (address) {
        return _vaultStorage().blockedFundsReceiver;
    }

    function instantFeeBps() public view returns (uint256) {
        return _vaultStorage().instantFeeBps;
    }

    function instantDailyLimitWad() public view returns (uint256) {
        return _vaultStorage().instantDailyLimitWad;
    }

    function minAmountWad() public view returns (uint256) {
        return _vaultStorage().minAmountWad;
    }

    function minFirstAmountWad() public view returns (uint256) {
        return _vaultStorage().minFirstAmountWad;
    }

    function variationToleranceBps() public view returns (uint256) {
        return _vaultStorage().variationToleranceBps;
    }

    function isFeeWaived(address account) public view returns (bool) {
        return _vaultStorage().feeWaived[account];
    }

    function isMinAmountWaived(address account) public view returns (bool) {
        return _vaultStorage().minAmountWaived[account];
    }

    /// @dev Instant volume already spent in the current UTC calendar day.
    function spentTodayWad() external view returns (uint256) {
        return _vaultStorage().dailySpentWad[block.timestamp / 1 days];
    }

    function nextRequestId() external view returns (uint256) {
        return _vaultStorage().nextRequestId;
    }

    /// @dev Moves the escrow to `to`, reverting if the transfer fails; the caller decides what
    ///      that means. One hook, not a refund/sweep pair: a refund IS a move to
    ///      `request.owner`, and two implementations are two chances to drift.
    function _moveEscrow(Request storage request, address to) internal virtual;

    function _vaultStorage() internal pure returns (ManageableVaultStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MANAGEABLE_VAULT_STORAGE_LOCATION
        }
    }

    function _pendingRequest(uint256 requestId) internal view returns (Request storage request) {
        request = _vaultStorage().requests[requestId];
        if (request.status != RequestStatus.Pending) revert RequestNotPending(requestId);
    }

    /// @return settled True when the money actually moved. False means the payment token
    ///         refused it: the request stays `Pending`, the flag is raised, and the caller must
    ///         NOT mark the request resolved.
    function _settleRefund(uint256 requestId, Request storage request) private returns (bool settled) {
        if (_tryRefund(requestId)) {
            request.refundBlocked = false;
            return true;
        }

        request.refundBlocked = true;
        emit RefundBlocked(requestId, request.owner, request.paymentToken);
        return false;
    }

    /// @dev Returns false ONLY when the transfer itself was refused.
    ///
    ///      The gas floor is checked BEFORE the attempt, not inferred afterwards. EIP-150
    ///      forwards at most 63/64 of available gas to a child frame, so a caller supplying a
    ///      tight limit could make the inner transfer run out while this frame survives on the
    ///      retained 1/64. Recording that as "the token refused" would let anyone able to call
    ///      `rejectRequest` — an operational hot-key role — latch `refundBlocked` on every
    ///      pending request without any token having refused anything.
    function _tryRefund(uint256 requestId) private returns (bool) {
        if (gasleft() < MIN_REFUND_GAS) revert RefundGasExhausted(requestId);

        try this.performEscrowRefund(requestId) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Pull-then-measure. The credited amount is the balance DELTA, never the requested
    ///      amount, so a fee-on-transfer token cannot be credited for value it never delivered.
    function _pullPaymentToken(address token, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();

        IERC20 erc20 = IERC20(token);
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        received = erc20.balanceOf(address(this)) - balanceBefore;

        // "The token delivered nothing" is exactly the question; a tolerance would let a
        // 100%-fee token through with a zero credit.
        // slither-disable-next-line incorrect-equality
        if (received == 0) revert ZeroAmount();
    }

    function _requireEnabledToken(address token) internal view returns (TokenConfig storage config) {
        ManageableVaultStorage storage $ = _vaultStorage();
        if (!_isRegistered($, token)) revert TokenNotConfigured(token);
        config = $.tokensConfig[token];
        if (!config.enabled) revert TokenDisabled(token);
    }

    function _effectiveFeeBps(address account, uint256 tokenFeeBps) internal view returns (uint256) {
        ManageableVaultStorage storage $ = _vaultStorage();
        if ($.feeWaived[account]) return 0;
        return $.instantFeeBps + tokenFeeBps;
    }

    /// @dev Rounds AWAY from zero so dust accrues to the protocol, never against it.
    function _feeOf(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(amount, feeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    function _requireAboveMinimum(address account, uint256 amountWad, bool isFirst) internal view {
        ManageableVaultStorage storage $ = _vaultStorage();
        if ($.minAmountWaived[account]) return;

        uint256 minimum = isFirst ? $.minFirstAmountWad : $.minAmountWad;
        if (amountWad < minimum) revert AmountBelowMinimum(amountWad, minimum);
    }

    /// @dev A calendar bucket, not a rolling window: the rolling variant needs per-account
    ///      history and costs far more. The consequence — spending the full limit late on one
    ///      day and again early on the next allows up to 2x within some 24h window — is in the
    ///      deviation register, asserted as an invariant, and a sizing rule in FORKING.md.
    function _chargeDailyLimit(uint256 amountWad) internal {
        ManageableVaultStorage storage $ = _vaultStorage();
        uint256 day = block.timestamp / 1 days;
        uint256 spent = $.dailySpentWad[day];
        uint256 limit = $.instantDailyLimitWad;

        // `spent` can exceed `limit` after VAULT_ADMIN lowers it mid-day, so the remaining
        // budget is clamped: `limit - spent` would panic and replace the informative error
        // with a bare 0x11.
        if (spent + amountWad > limit) {
            revert DailyLimitExceeded(amountWad, spent >= limit ? 0 : limit - spent);
        }
        $.dailySpentWad[day] = spent + amountWad;
    }

    function _chargeTokenAllowance(address token, uint256 amountWad) internal {
        TokenConfig storage config = _vaultStorage().tokensConfig[token];
        uint256 remaining = config.remainingAllowanceWad;
        if (remaining == type(uint256).max) return;

        if (amountWad > remaining) revert TokenAllowanceExceeded(token, amountWad, remaining);
        config.remainingAllowanceWad = remaining - amountWad;
    }

    /// @return oracleRateWad The rate the check ran against, for the event log.
    function _requireRateWithinTolerance(uint256 operatorRateWad) internal view returns (uint256 oracleRateWad) {
        ManageableVaultStorage storage $ = _vaultStorage();
        oracleRateWad = $.dataFeed.getPrice();

        uint256 gap = operatorRateWad > oracleRateWad
            ? operatorRateWad - oracleRateWad
            : oracleRateWad - operatorRateWad;

        // Rounded UP, like every money-adjacent computation here: rounding the measured
        // deviation down would let an operator price fractionally further from the oracle than
        // the tolerance nominally allows.
        if (Math.mulDiv(gap, BPS_DENOMINATOR, oracleRateWad, Math.Rounding.Ceil) > $.variationToleranceBps) {
            revert RateOutsideTolerance(operatorRateWad, oracleRateWad, $.variationToleranceBps);
        }
    }

    function _recordRequest(
        address owner,
        address token,
        uint256 amountWad,
        uint256 feeBpsPinned,
        uint8 decimalsPinned,
        uint256 minOutWad
    ) internal returns (uint256 requestId) {
        ManageableVaultStorage storage $ = _vaultStorage();
        requestId = $.nextRequestId;
        ++$.nextRequestId;

        $.requests[requestId] = Request({
            owner: owner,
            decimalsPinned: decimalsPinned,
            status: RequestStatus.Pending,
            refundBlocked: false,
            paymentToken: token,
            amountWad: amountWad,
            feeBpsPinned: feeBpsPinned,
            minOutWad: minOutWad,
            submittedAt: block.timestamp
        });

        emit RequestSubmitted(requestId, owner, token, amountWad, minOutWad);
    }

    /// @dev An explicit flag rather than a `decimals != 0` sentinel, which made "registered"
    ///      and "declares zero decimals" the same state: a zero-decimals token would be pushed
    ///      onto the append-only list while reading back as unregistered — permanently
    ///      unusable, un-updatable and un-removable. The flag packs into an existing slot.
    function _isRegistered(
        ManageableVaultStorage storage $,
        address token
    ) private view returns (bool) {
        return $.tokensConfig[token].registered;
    }

    function _setInstantFeeBps(ManageableVaultStorage storage $, uint256 newBps) private {
        if (newBps > MAX_INSTANT_FEE_BPS) revert ConfigOutOfRange();
        emit InstantFeeUpdated($.instantFeeBps, newBps);
        $.instantFeeBps = newBps;
    }

    function _setInstantDailyLimitWad(ManageableVaultStorage storage $, uint256 newLimitWad) private {
        // A zero limit would stop every instant operation while looking like a configuration
        // value rather than a pause.
        if (newLimitWad == 0) revert ConfigOutOfRange();
        emit InstantDailyLimitUpdated($.instantDailyLimitWad, newLimitWad);
        $.instantDailyLimitWad = newLimitWad;
    }

    function _setMinAmounts(
        ManageableVaultStorage storage $,
        uint256 newMinAmountWad,
        uint256 newMinFirstAmountWad
    ) private {
        if (newMinAmountWad > MAX_MIN_AMOUNT_WAD || newMinFirstAmountWad > MAX_MIN_AMOUNT_WAD) {
            revert ConfigOutOfRange();
        }
        if (newMinFirstAmountWad < newMinAmountWad) revert ConfigOutOfRange();

        $.minAmountWad = newMinAmountWad;
        $.minFirstAmountWad = newMinFirstAmountWad;
        emit MinAmountsUpdated(newMinAmountWad, newMinFirstAmountWad);
    }

    function _setVariationToleranceBps(ManageableVaultStorage storage $, uint256 newBps) private {
        if (newBps > MAX_VARIATION_TOLERANCE_BPS) revert ConfigOutOfRange();
        emit VariationToleranceUpdated($.variationToleranceBps, newBps);
        $.variationToleranceBps = newBps;
    }

    function _setReceivers(
        ManageableVaultStorage storage $,
        address newTokensReceiver,
        address newFeeReceiver,
        address newBlockedFundsReceiver
    ) private {
        if (
            newTokensReceiver == address(0) ||
            newFeeReceiver == address(0) ||
            newBlockedFundsReceiver == address(0)
        ) {
            revert ConfigOutOfRange();
        }

        $.tokensReceiver = newTokensReceiver;
        $.feeReceiver = newFeeReceiver;
        $.blockedFundsReceiver = newBlockedFundsReceiver;
        emit ReceiversUpdated(newTokensReceiver, newFeeReceiver, newBlockedFundsReceiver);
    }

    function _authorizeUpgrade(address) internal override onlyRegistryRole(upgraderRole()) {}
}
