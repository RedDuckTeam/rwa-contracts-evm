// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Roles} from "../access/Roles.sol";
import {DecimalsConverter} from "../libraries/DecimalsConverter.sol";
import {ManageableVault} from "./ManageableVault.sol";

/// @dev Exit side. Holds BURNER_ROLE and REFUND_VAULT_ROLE, and deliberately NOT MINTER_ROLE.
///
///      Liquidity is NOT held here: payouts are pulled from `tokensProvider`, so this contract
///      never becomes a standing pot of stablecoins. The cost is that a payout fails outright
///      when the provider is short on balance or allowance, which {ProviderShortfall} names
///      rather than letting an opaque ERC-20 revert stand in for it.
///
///      Escrow here is the NAV TOKEN, so refunds go through the token's `refundFromVault`
///      carve-out and survive both a transfer pause and a blacklisted owner. Sanctions are the
///      one thing that still stops them — precisely the case
///      {ManageableVault-sweepBlockedRefund} exists to resolve.
contract RedemptionVault is ManageableVault {
    using SafeERC20 for IERC20;
    using DecimalsConverter for uint256;

    /// @custom:storage-location erc7201:rwa.storage.RedemptionVault
    struct RedemptionVaultStorage {
        address tokensProvider;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.RedemptionVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REDEMPTION_VAULT_STORAGE_LOCATION =
        0xe55f78a378935f6e12e0437ca883249b5c4575ecc216f0b4456fd6fdb7d10e00;

    event TokensProviderUpdated(address indexed previousProvider, address indexed newProvider);
    event InstantRedemption(
        address indexed account,
        address indexed paymentToken,
        uint256 burnedWad,
        uint256 feeWad,
        uint256 paidOutWad,
        uint256 rateWad
    );
    event RedemptionApproved(uint256 indexed requestId, address indexed owner, uint256 paidOutWad);

    /// @dev An error rather than an event: an event emitted immediately before a revert is
    ///      erased with the rest of the transaction and never reaches a monitor. Revert data
    ///      does.
    error ProviderShortfall(address provider, address token, uint256 requiredTokens, uint256 availableTokens);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param tokensProvider_ Must have approved this vault. Defaults to the deposit treasury
    ///        in the reference deployment.
    function initialize(
        VaultInitParams calldata params,
        address tokensProvider_
    ) external initializer {
        __ManageableVault_init(params);
        _setTokensProvider(tokensProvider_);
    }

    function supportedOperations() public pure override returns (bytes32[] memory ops) {
        ops = new bytes32[](2);
        ops[0] = Roles.OP_REDEEM_INSTANT;
        ops[1] = Roles.OP_REDEEM_REQUEST;
    }

    /// @param minOutTokens Floor on the payout, in the payment token's own units.
    function redeemInstant(
        address paymentToken,
        uint256 amountWad,
        uint256 minOutTokens
    )
        external
        nonReentrant
        whenOperationNotPaused(Roles.OP_REDEEM_INSTANT)
        onlyCompliantCaller
        returns (uint256 paidOutTokens)
    {
        TokenConfig storage config = _requireEnabledToken(paymentToken);
        uint8 tokenDecimals = config.decimals;
        uint256 feeBps = _effectiveFeeBps(msg.sender, config.feeBps);

        if (amountWad == 0) revert ZeroAmount();
        _requireAboveMinimum(msg.sender, amountWad, false);

        // Escrow first, then burn from this contract: the movement stays visible as an
        // ordinary transfer and the burn is a single-party operation.
        IERC20(address(rwaToken())).safeTransferFrom(msg.sender, address(this), amountWad);

        uint256 feeWad = _feeOf(amountWad, feeBps);
        uint256 burnWad = amountWad - feeWad;

        uint256 rateWad = dataFeed().getPrice();
        uint256 payoutWad = Math.mulDiv(burnWad, rateWad, WAD);
        paidOutTokens = payoutWad.fromWadDown(tokenDecimals);
        if (paidOutTokens < minOutTokens) revert SlippageExceeded(paidOutTokens, minOutTokens);

        _chargeDailyLimit(amountWad);
        _chargeTokenAllowance(paymentToken, payoutWad);

        // The fee stays denominated in the NAV token and is handed over rather than burned, so
        // the supply invariant stays exactly "minted minus burned". Sent as an ORDINARY
        // transfer, not through the privileged refund path: the carve-out exists to stop exits
        // being trapped, and paying a fee is not an exit.
        if (feeWad != 0) IERC20(address(rwaToken())).safeTransfer(feeReceiver(), feeWad);
        rwaToken().burn(address(this), burnWad);

        _payOut(paymentToken, msg.sender, paidOutTokens);

        emit InstantRedemption(msg.sender, paymentToken, burnWad, feeWad, payoutWad, rateWad);
    }

    /// @param minOutTokens Floor on the eventual payout, in the payment token's units.
    function redeemRequest(
        address paymentToken,
        uint256 amountWad,
        uint256 minOutTokens
    )
        external
        nonReentrant
        whenOperationNotPaused(Roles.OP_REDEEM_REQUEST)
        onlyCompliantCaller
        returns (uint256 requestId)
    {
        TokenConfig storage config = _requireEnabledToken(paymentToken);
        uint256 feeBps = _effectiveFeeBps(msg.sender, config.feeBps);

        if (amountWad == 0) revert ZeroAmount();
        _requireAboveMinimum(msg.sender, amountWad, false);

        IERC20(address(rwaToken())).safeTransferFrom(msg.sender, address(this), amountWad);

        requestId = _recordRequest(
            msg.sender,
            paymentToken,
            amountWad,
            feeBps,
            config.decimals,
            minOutTokens
        );
    }

    function approveRedeemRequest(
        uint256 requestId,
        uint256 operatorRateWad
    )
        external
        nonReentrant
        whenOperationNotPaused(Roles.OP_REDEEM_REQUEST)
        onlyRegistryRole(requestOperatorRole())
        returns (uint256 paidOutTokens)
    {
        Request storage request = _pendingRequest(requestId);
        uint256 oracleRateWad = _requireRateWithinTolerance(operatorRateWad);

        uint256 feeWad = _feeOf(request.amountWad, request.feeBpsPinned);
        uint256 burnWad = request.amountWad - feeWad;

        uint256 payoutWad = Math.mulDiv(burnWad, operatorRateWad, WAD);
        paidOutTokens = payoutWad.fromWadDown(request.decimalsPinned);
        if (paidOutTokens < request.minOutWad) revert SlippageExceeded(paidOutTokens, request.minOutWad);

        _chargeTokenAllowance(request.paymentToken, payoutWad);

        request.status = RequestStatus.Approved;

        if (feeWad != 0) IERC20(address(rwaToken())).safeTransfer(feeReceiver(), feeWad);
        rwaToken().burn(address(this), burnWad);

        _payOut(request.paymentToken, request.owner, paidOutTokens);

        emit RequestApproved(requestId, operatorRateWad, oracleRateWad, payoutWad);
        emit RedemptionApproved(requestId, request.owner, payoutWad);
    }

    function tokensProvider() public view returns (address) {
        return _redemptionVaultStorage().tokensProvider;
    }

    function setTokensProvider(address newProvider) external onlyRegistryRole(criticalConfigRole()) {
        _setTokensProvider(newProvider);
    }

    /// @inheritdoc ManageableVault
    /// @dev Uses the token's privileged path, so neither a transfer pause nor a blacklisted
    ///      owner can strand escrow — and a sweep cannot be defeated by the very pause that
    ///      made the ordinary refund fail. Sanctions still stop it, which is exactly what makes
    ///      a request sweep-eligible.
    ///
    ///      The returned bool is ERC-7943 shape; failure is signalled by revert, which is what
    ///      the caller's try/catch watches for.
    // slither-disable-next-line unused-return
    function _moveEscrow(Request storage request, address to) internal override {
        rwaToken().refundFromVault(to, request.amountWad);
    }

    /// @dev Pulls the payout from the provider straight to the recipient, so the vault is never
    ///      a resting place for liquidity. Balance and allowance are checked up front to name
    ///      the shortfall rather than surfacing a bare ERC-20 revert.
    function _payOut(address paymentToken, address to, uint256 amountTokens) private {
        if (amountTokens == 0) return;

        address provider = _redemptionVaultStorage().tokensProvider;
        IERC20 erc20 = IERC20(paymentToken);

        uint256 available = Math.min(erc20.balanceOf(provider), erc20.allowance(provider, address(this)));
        if (available < amountTokens) {
            revert ProviderShortfall(provider, paymentToken, amountTokens, available);
        }

        // `provider` is not user input: it is a CRITICAL_CONFIG address that has explicitly
        // approved this vault. Pulling straight from it to the recipient keeps liquidity out
        // of this contract instead of pooling it here.
        // slither-disable-next-line arbitrary-send-erc20
        erc20.safeTransferFrom(provider, to, amountTokens);
    }

    function _setTokensProvider(address newProvider) private {
        if (newProvider == address(0)) revert ConfigOutOfRange();
        emit TokensProviderUpdated(_redemptionVaultStorage().tokensProvider, newProvider);
        _redemptionVaultStorage().tokensProvider = newProvider;
    }

    function _redemptionVaultStorage() private pure returns (RedemptionVaultStorage storage $) {
        assembly ("memory-safe") {
            $.slot := REDEMPTION_VAULT_STORAGE_LOCATION
        }
    }
}
