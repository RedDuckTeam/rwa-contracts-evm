// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Roles} from "../access/Roles.sol";
import {DecimalsConverter} from "../libraries/DecimalsConverter.sol";
import {ManageableVault} from "./ManageableVault.sol";

/// @dev Issuance side. Holds MINTER_ROLE and deliberately NOT BURNER_ROLE: split across two
///      contracts, a bug on the issuance side cannot destroy supply and a bug on the
///      redemption side cannot create it. Deployment verification asserts both directions.
///
///      Escrow here is the PAYMENT token, so a blocked refund means the stablecoin's own
///      blacklist refused the transfer.
contract DepositVault is ManageableVault {
    using SafeERC20 for IERC20;
    using DecimalsConverter for uint256;

    /// @custom:storage-location erc7201:rwa.storage.DepositVault
    struct DepositVaultStorage {
        uint256 maxSupplyCapWad;
        mapping(address account => bool hasDeposited) hasDeposited;
    }

    // keccak256(abi.encode(uint256(keccak256("rwa.storage.DepositVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DEPOSIT_VAULT_STORAGE_LOCATION =
        0x99bf3295010fc2426acb8b98ea4e1c07f98113bc19f8fc48c8de5f2a765f0900;

    event MaxSupplyCapUpdated(uint256 previousCapWad, uint256 newCapWad);
    event InstantDeposit(
        address indexed account,
        address indexed paymentToken,
        uint256 amountInWad,
        uint256 feeWad,
        uint256 mintedWad,
        uint256 rateWad
    );
    event DepositApproved(uint256 indexed requestId, address indexed owner, uint256 mintedWad);

    error MaxSupplyCapExceeded(uint256 wouldBeSupplyWad, uint256 capWad);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        VaultInitParams calldata params,
        uint256 maxSupplyCapWad_
    ) external initializer {
        __ManageableVault_init(params);
        _setMaxSupplyCapWad(maxSupplyCapWad_);
    }

    function supportedOperations() public pure override returns (bytes32[] memory ops) {
        ops = new bytes32[](2);
        ops[0] = Roles.OP_DEPOSIT_INSTANT;
        ops[1] = Roles.OP_DEPOSIT_REQUEST;
    }

    /// @param minOutWad The caller's protection against NAV moving between broadcast and
    ///        inclusion.
    function depositInstant(
        address paymentToken,
        uint256 amountIn,
        uint256 minOutWad
    )
        external
        nonReentrant
        whenOperationNotPaused(Roles.OP_DEPOSIT_INSTANT)
        onlyCompliantCaller
        returns (uint256 mintedWad)
    {
        TokenConfig storage config = _requireEnabledToken(paymentToken);
        uint8 tokenDecimals = config.decimals;
        uint256 feeBps = _effectiveFeeBps(msg.sender, config.feeBps);

        uint256 received = _pullPaymentToken(paymentToken, amountIn);
        uint256 receivedWad = received.toWad(tokenDecimals);

        _requireAboveMinimum(msg.sender, receivedWad, _isFirstDeposit(msg.sender));
        _chargeTokenAllowance(paymentToken, receivedWad);

        // Fee is computed in TOKEN units so the split is exact: the two legs always sum back
        // to what was actually received, with no dust left in the vault.
        uint256 feeTokens = _feeOf(received, feeBps);
        uint256 bodyTokens = received - feeTokens;

        uint256 rateWad = dataFeed().getPrice();
        mintedWad = Math.mulDiv(bodyTokens.toWad(tokenDecimals), WAD, rateWad);
        if (mintedWad < minOutWad) revert SlippageExceeded(mintedWad, minOutWad);

        _chargeDailyLimit(mintedWad);
        _requireWithinSupplyCap(mintedWad);

        _forward(paymentToken, feeTokens, bodyTokens);
        _markDeposited(msg.sender);
        rwaToken().mint(msg.sender, mintedWad);

        emit InstantDeposit(
            msg.sender,
            paymentToken,
            receivedWad,
            feeTokens.toWad(tokenDecimals),
            mintedWad,
            rateWad
        );
    }

    /// @dev The fee and decimals are pinned now. Neither the daily limit nor the supply cap
    ///      applies here — both are evaluated at approval, when the minted amount is known.
    function depositRequest(
        address paymentToken,
        uint256 amountIn,
        uint256 minOutWad
    )
        external
        nonReentrant
        whenOperationNotPaused(Roles.OP_DEPOSIT_REQUEST)
        onlyCompliantCaller
        returns (uint256 requestId)
    {
        TokenConfig storage config = _requireEnabledToken(paymentToken);
        uint8 tokenDecimals = config.decimals;
        uint256 feeBps = _effectiveFeeBps(msg.sender, config.feeBps);

        uint256 received = _pullPaymentToken(paymentToken, amountIn);
        uint256 receivedWad = received.toWad(tokenDecimals);

        _requireAboveMinimum(msg.sender, receivedWad, _isFirstDeposit(msg.sender));

        requestId = _recordRequest(msg.sender, paymentToken, receivedWad, feeBps, tokenDecimals, minOutWad);
    }

    /// @param operatorRateWad Must sit within `variationToleranceBps` of the live oracle rate.
    function approveDepositRequest(
        uint256 requestId,
        uint256 operatorRateWad
    )
        external
        nonReentrant
        whenOperationNotPaused(Roles.OP_DEPOSIT_REQUEST)
        onlyRegistryRole(requestOperatorRole())
        returns (uint256 mintedWad)
    {
        Request storage request = _pendingRequest(requestId);
        uint256 oracleRateWad = _requireRateWithinTolerance(operatorRateWad);

        uint256 escrowTokens = request.amountWad.fromWadDown(request.decimalsPinned);
        uint256 feeTokens = _feeOf(escrowTokens, request.feeBpsPinned);
        uint256 bodyTokens = escrowTokens - feeTokens;

        mintedWad = Math.mulDiv(bodyTokens.toWad(request.decimalsPinned), WAD, operatorRateWad);
        if (mintedWad < request.minOutWad) revert SlippageExceeded(mintedWad, request.minOutWad);

        _chargeTokenAllowance(request.paymentToken, request.amountWad);
        _requireWithinSupplyCap(mintedWad);

        request.status = RequestStatus.Approved;

        _forward(request.paymentToken, feeTokens, bodyTokens);
        _markDeposited(request.owner);
        rwaToken().mint(request.owner, mintedWad);

        emit RequestApproved(requestId, operatorRateWad, oracleRateWad, mintedWad);
        emit DepositApproved(requestId, request.owner, mintedWad);
    }

    function maxSupplyCapWad() public view returns (uint256) {
        return _depositVaultStorage().maxSupplyCapWad;
    }

    function hasDeposited(address account) public view returns (bool) {
        return _depositVaultStorage().hasDeposited[account];
    }

    function setMaxSupplyCapWad(uint256 newCapWad) external onlyRegistryRole(vaultAdminRole()) {
        _setMaxSupplyCapWad(newCapWad);
    }

    /// @inheritdoc ManageableVault
    /// @dev Moves the escrowed PAYMENT token — the transfer a stablecoin's own blacklist can
    ///      refuse, which is what makes the blocked-refund path reachable.
    function _moveEscrow(Request storage request, address to) internal override {
        IERC20(request.paymentToken).safeTransfer(
            to,
            request.amountWad.fromWadDown(request.decimalsPinned)
        );
    }

    /// @dev Both halves matter: someone who received tokens by transfer is already a holder,
    ///      and re-imposing the higher entry minimum on them would be arbitrary.
    function _isFirstDeposit(address account) private view returns (bool) {
        if (_depositVaultStorage().hasDeposited[account]) return false;
        // "Holds nothing at all" is exactly the question; there is no tolerance to apply.
        // slither-disable-next-line incorrect-equality
        return rwaToken().balanceOf(account) == 0;
    }

    function _markDeposited(address account) private {
        _depositVaultStorage().hasDeposited[account] = true;
    }

    function _requireWithinSupplyCap(uint256 mintedWad) private view {
        uint256 cap = _depositVaultStorage().maxSupplyCapWad;
        uint256 wouldBe = rwaToken().totalSupply() + mintedWad;
        if (wouldBe > cap) revert MaxSupplyCapExceeded(wouldBe, cap);
    }

    /// @dev Pull-then-forward: nothing accumulates here. Fee and body leave in the same
    ///      transaction they arrived, to two separately configured addresses.
    function _forward(address paymentToken, uint256 feeTokens, uint256 bodyTokens) private {
        IERC20 erc20 = IERC20(paymentToken);
        if (feeTokens != 0) erc20.safeTransfer(feeReceiver(), feeTokens);
        if (bodyTokens != 0) erc20.safeTransfer(tokensReceiver(), bodyTokens);
    }

    function _setMaxSupplyCapWad(uint256 newCapWad) private {
        // Zero would halt issuance while presenting as a parameter rather than a pause.
        if (newCapWad == 0) revert ConfigOutOfRange();
        emit MaxSupplyCapUpdated(_depositVaultStorage().maxSupplyCapWad, newCapWad);
        _depositVaultStorage().maxSupplyCapWad = newCapWad;
    }

    function _depositVaultStorage() private pure returns (DepositVaultStorage storage $) {
        assembly ("memory-safe") {
            $.slot := DEPOSIT_VAULT_STORAGE_LOCATION
        }
    }
}
