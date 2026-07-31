// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {WithAccessRegistry} from "../../contracts/access/WithAccessRegistry.sol";
import {ComplianceRegistry} from "../../contracts/compliance/ComplianceRegistry.sol";
import {OperationPausable} from "../../contracts/pause/OperationPausable.sol";
import {RwaToken} from "../../contracts/token/RwaToken.sol";
import {ManageableVault} from "../../contracts/vaults/ManageableVault.sol";
import {RedemptionVault} from "../../contracts/vaults/RedemptionVault.sol";
import {ReentrantPaymentToken} from "../../contracts/mocks/ReentrantPaymentToken.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract RedemptionVaultTest is PlatformFixture {
    function setUp() public {
        _deployPlatform();
        _fundWithUsdc(alice, 1_000_000e6);
        _fundWithUsdc(bob, 1_000_000e6);

        // Give both parties a NAV-token balance to redeem, and approve the exit vault.
        vm.startPrank(alice);
        depositVault.depositInstant(address(usdc), 100_000e6, 0);
        token.approve(address(redemptionVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        depositVault.depositInstant(address(usdc), 100_000e6, 0);
        token.approve(address(redemptionVault), type(uint256).max);
        vm.stopPrank();
    }

    function test_InstantRedemptionBurnsAndPaysFromTheProvider() public {
        uint256 supplyBefore = token.totalSupply();
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 paidOut = redemptionVault.redeemInstant(address(usdc), 10_000e18, 0);

        // 1% fee stays denominated in the NAV token; 9 900 is burned at NAV 1.00.
        assertEq(paidOut, 9_900e6);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 9_900e6);
        assertEq(token.balanceOf(feeCollector), 100e18);
        assertEq(supplyBefore - token.totalSupply(), 9_900e18);

        // Liquidity never rests in the vault.
        assertEq(usdc.balanceOf(address(redemptionVault)), 0);
        assertEq(token.balanceOf(address(redemptionVault)), 0);
    }

    function test_InstantRedemptionRespectsMinOut() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.SlippageExceeded.selector, 9_900e6, 10_000e6)
        );
        redemptionVault.redeemInstant(address(usdc), 10_000e18, 10_000e6);
    }

    function test_RedemptionUsesTheLiveNav() public {
        _postNav(1.01e8); // NAV up 1%

        vm.prank(alice);
        uint256 paidOut = redemptionVault.redeemInstant(address(usdc), 10_000e18, 0);

        assertEq(paidOut, 9_999e6); // 9 900 * 1.01
    }

    /// @dev Payouts are pulled from the provider, so the vault is never a standing pot. The
    ///      trade-off is that a short provider fails the payout outright, named specifically
    ///      rather than surfacing an opaque ERC-20 revert.
    function test_RevertWhen_ProviderCannotCoverThePayout() public {
        vm.prank(treasury);
        usdc.approve(address(redemptionVault), 100e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                RedemptionVault.ProviderShortfall.selector,
                treasury,
                address(usdc),
                9_900e6,
                100e6
            )
        );
        redemptionVault.redeemInstant(address(usdc), 10_000e18, 0);
    }

    function test_TimelockCanRepointTheProvider() public {
        address newProvider = makeAddr("newProvider");
        usdc.mint(newProvider, 1_000_000e6);
        vm.prank(newProvider);
        usdc.approve(address(redemptionVault), type(uint256).max);

        _executeViaTimelock(
            address(redemptionVault),
            abi.encodeCall(redemptionVault.setTokensProvider, (newProvider))
        );

        assertEq(redemptionVault.tokensProvider(), newProvider);

        vm.prank(alice);
        redemptionVault.redeemInstant(address(usdc), 10_000e18, 0);
        assertEq(usdc.balanceOf(newProvider), 1_000_000e6 - 9_900e6);
    }

    function test_RevertWhen_ProviderIsChangedOutsideTheTimelock() public {
        vm.prank(vaultAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                vaultAdmin
            )
        );
        redemptionVault.setTokensProvider(bob);
    }

    function test_RevertWhen_ProviderWouldBeZero() public {
        vm.prank(address(timelock));
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        redemptionVault.setTokensProvider(address(0));
    }

    function test_RevertWhen_RedemptionAmountIsZeroOrBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(ManageableVault.ZeroAmount.selector);
        redemptionVault.redeemInstant(address(usdc), 0, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.AmountBelowMinimum.selector, 1e18, MIN_AMOUNT_WAD)
        );
        redemptionVault.redeemInstant(address(usdc), 1e18, 0);
    }

    function test_RevertWhen_RedemptionExceedsTheDailyLimit() public {
        vm.prank(vaultAdmin);
        redemptionVault.setInstantDailyLimitWad(10_000e18);

        vm.prank(alice);
        redemptionVault.redeemInstant(address(usdc), 10_000e18, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ManageableVault.DailyLimitExceeded.selector, 1_000e18, 0));
        redemptionVault.redeemInstant(address(usdc), 1_000e18, 0);
    }

    function test_RevertWhen_RedemptionIsPausedOrCallerIsBlocked() public {
        _grantOperational(Roles.PAUSER_ROLE, pauser);
        vm.prank(pauser);
        redemptionVault.pauseOperation(Roles.OP_REDEEM_INSTANT);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OperationPausable.OperationIsPaused.selector,
                Roles.OP_REDEEM_INSTANT
            )
        );
        redemptionVault.redeemInstant(address(usdc), 10_000e18, 0);

        // Lift the pause so the next assertion is about compliance rather than hitting the
        // pause check first.
        _grantOperational(Roles.UNPAUSER_ROLE, unpauser);
        vm.prank(unpauser);
        redemptionVault.unpauseOperation(Roles.OP_REDEEM_INSTANT);

        _blacklist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, bob));
        redemptionVault.redeemInstant(address(usdc), 10_000e18, 0);
    }

    function test_RequestEscrowsTheNavTokenAndApprovalSettles() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        assertEq(token.balanceOf(address(redemptionVault)), 10_000e18);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(requestOperator);
        uint256 paidOut = redemptionVault.approveRedeemRequest(requestId, 1e18);

        assertEq(paidOut, 9_900e6);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 9_900e6);
        assertEq(token.balanceOf(address(redemptionVault)), 0);
        assertEq(
            uint8(redemptionVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Approved)
        );
    }

    function test_RevertWhen_RedemptionRateIsOutsideTolerance() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        vm.prank(requestOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManageableVault.RateOutsideTolerance.selector,
                0.98e18,
                1e18,
                VARIATION_TOLERANCE_BPS
            )
        );
        redemptionVault.approveRedeemRequest(requestId, 0.98e18);
    }

    function test_RevertWhen_RedemptionRequestAmountIsZero() public {
        vm.prank(alice);
        vm.expectRevert(ManageableVault.ZeroAmount.selector);
        redemptionVault.redeemRequest(address(usdc), 0, 0);
    }

    /// @dev Pinned at submission, enforced at approval, so an operator cannot settle below what
    ///      the owner agreed to accept.
    function test_RevertWhen_RedemptionApprovalWouldBreachMinOut() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 9_950e6);

        vm.prank(requestOperator);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.SlippageExceeded.selector, 9_900e6, 9_950e6)
        );
        redemptionVault.approveRedeemRequest(requestId, 1e18);
    }

    function test_RejectReturnsTheEscrowedNavToken() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        vm.prank(requestOperator);
        redemptionVault.rejectRequest(requestId);

        assertEq(token.balanceOf(alice), balanceBefore);
    }

    /// @dev Why the token has a privileged refund path at all: a user must be able to walk away
    ///      from an unresolved request even while transfers are frozen.
    function test_CancelReturnsEscrowEvenWhileTransfersArePaused() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        _grantOperational(Roles.PAUSER_ROLE, pauser);
        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        // An ordinary transfer is dead...
        vm.prank(bob);
        vm.expectRevert(RwaToken.TransfersPaused.selector);
        token.transfer(alice, 1e18);

        // ...but the exit is not.
        vm.prank(alice);
        redemptionVault.cancelRequest(requestId);
        assertEq(token.balanceOf(alice), balanceBefore);
    }

    /// @dev Being blacklisted must not turn into confiscation of an unresolved request.
    function test_CancelReturnsEscrowToABlacklistedOwner() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        _blacklist(alice);

        vm.prank(alice);
        redemptionVault.cancelRequest(requestId);
        assertEq(token.balanceOf(alice), balanceBefore);
    }

    /// @dev Reject requires no price, so it works during exactly the incident that made the feed
    ///      unusable — closing the free option a cancellable, never-expiring request would
    ///      otherwise hand the user.
    function test_RejectWorksWhileTheFeedIsUnhealthy() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        vm.warp(block.timestamp + HEALTHY_DIFF + 1);

        // Approval is impossible without a price...
        vm.prank(requestOperator);
        vm.expectRevert();
        redemptionVault.approveRedeemRequest(requestId, 1e18);

        // ...yet the operator can still unwind it.
        vm.prank(requestOperator);
        redemptionVault.rejectRequest(requestId);
        assertEq(
            uint8(redemptionVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Rejected)
        );
    }

    /// @dev Sanctions are the one control the carve-out does not relax, so the cancellation
    ///      completes without moving money.
    function test_CancelIsBlockedForASanctionedOwner() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        sanctions.setSanctioned(alice, true);

        vm.expectEmit(true, true, true, false, address(redemptionVault));
        emit ManageableVault.RefundBlocked(requestId, alice, address(usdc));
        vm.prank(alice);
        redemptionVault.cancelRequest(requestId);

        ManageableVault.Request memory request = redemptionVault.getRequest(requestId);
        assertTrue(request.refundBlocked);
        assertEq(uint8(request.status), uint8(ManageableVault.RequestStatus.Pending));
        assertEq(token.balanceOf(address(redemptionVault)), 10_000e18);
    }

    function test_SanctionedOwnerEscrowIsSweptToTheBlockedFundsReceiver() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        sanctions.setSanctioned(alice, true);

        _executeViaTimelock(
            address(redemptionVault),
            abi.encodeCall(redemptionVault.sweepBlockedRefund, (requestId))
        );

        assertEq(token.balanceOf(blockedFunds), 10_000e18);
        assertEq(
            uint8(redemptionVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Swept)
        );
    }

    /// @dev Re-evaluated at execution time, so someone delisted during the 48h delay gets their
    ///      money back: a stale flag alone is never grounds to take funds.
    function test_SweepPaysAnOwnerDelistedDuringTheDelay() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        sanctions.setSanctioned(alice, true);
        vm.prank(alice);
        redemptionVault.cancelRequest(requestId); // records refundBlocked

        uint256 balanceBefore = token.balanceOf(alice);
        bytes memory payload = abi.encodeCall(redemptionVault.sweepBlockedRefund, (requestId));
        _scheduleViaTimelock(address(redemptionVault), payload);

        // Delisted while the proposal matured.
        sanctions.setSanctioned(alice, false);

        vm.expectEmit(true, true, false, true, address(redemptionVault));
        emit ManageableVault.RefundRecovered(requestId, alice, 10_000e18);
        _executeScheduled(address(redemptionVault), payload);

        assertEq(token.balanceOf(alice) - balanceBefore, 10_000e18);
        assertEq(token.balanceOf(blockedFunds), 0);
        assertEq(
            uint8(redemptionVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Cancelled)
        );
    }

    /// @dev A sweep must not be defeated by the very pause that made the refund fail, so it also
    ///      travels the privileged path.
    function test_SweepWorksWhileTransfersArePaused() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);
        sanctions.setSanctioned(alice, true);

        _grantOperational(Roles.PAUSER_ROLE, pauser);
        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        _executeViaTimelock(
            address(redemptionVault),
            abi.encodeCall(redemptionVault.sweepBlockedRefund, (requestId))
        );

        assertEq(token.balanceOf(blockedFunds), 10_000e18);
    }

    /// @dev The mirror of the deposit side: a bug here cannot create supply.
    function test_RedemptionVaultHasBurnerAndRefundButNotMinter() public view {
        assertTrue(registry.hasRole(Roles.BURNER_ROLE, address(redemptionVault)));
        assertTrue(registry.hasRole(Roles.REFUND_VAULT_ROLE, address(redemptionVault)));
        assertFalse(registry.hasRole(Roles.MINTER_ROLE, address(redemptionVault)));
    }

    /// @dev Exactly one holder: the claim deployment verification has to make.
    function test_RefundRoleIsHeldByTheRedemptionVaultAlone() public view {
        assertEq(registry.getRoleMemberCount(Roles.REFUND_VAULT_ROLE), 1);
        assertEq(registry.getRoleMember(Roles.REFUND_VAULT_ROLE, 0), address(redemptionVault));
    }

    /// @dev A vault accepting arbitrary ERC-20s runs the token's code mid-accounting.
    ///      `ReentrancyGuardTransient` is the defence; this proves it holds.
    function test_ReentrantPaymentTokenIsRejected() public {
        ReentrantPaymentToken hostile = new ReentrantPaymentToken();

        vm.prank(vaultAdmin);
        depositVault.addPaymentToken(address(hostile), 0, type(uint256).max);

        hostile.mint(alice, 100_000e6);
        vm.prank(alice);
        hostile.approve(address(depositVault), type(uint256).max);

        hostile.arm(
            address(depositVault),
            abi.encodeCall(depositVault.depositInstant, (address(hostile), 1_000e6, 0))
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReentrantPaymentToken.ReentrancyRejected.selector,
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            )
        );
        depositVault.depositInstant(address(hostile), 10_000e6, 0);
    }

    /// @dev Supply moves by exactly the burned amount and the fee is never burned, so
    ///      "totalSupply == minted - burned" survives every redemption.
    function testFuzz_SupplyMovesByExactlyTheBurnedAmount(uint96 amountWad, uint16 feeBps) public {
        amountWad = uint96(bound(amountWad, MIN_AMOUNT_WAD, 50_000e18));
        feeBps = uint16(bound(feeBps, 0, redemptionVault.MAX_INSTANT_FEE_BPS()));

        vm.prank(vaultAdmin);
        redemptionVault.setInstantFeeBps(feeBps);

        uint256 supplyBefore = token.totalSupply();
        uint256 feeHeldBefore = token.balanceOf(feeCollector);

        vm.prank(alice);
        redemptionVault.redeemInstant(address(usdc), amountWad, 0);

        uint256 burned = supplyBefore - token.totalSupply();
        uint256 feeTaken = token.balanceOf(feeCollector) - feeHeldBefore;

        assertEq(burned + feeTaken, amountWad, "burn plus fee must equal the input");
        assertEq(token.balanceOf(address(redemptionVault)), 0, "vault retained NAV tokens");
    }

    /// @dev A deposit followed immediately by a full redemption can never return more than was
    ///      put in; if it could, the round trip would be a money pump.
    function testFuzz_RoundTripNeverExtractsValue(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1_000e6, 200_000e6));

        address carol = makeAddr("carol");
        _fundWithUsdc(carol, uint256(amountIn));

        vm.startPrank(carol);
        uint256 minted = depositVault.depositInstant(address(usdc), amountIn, 0);
        token.approve(address(redemptionVault), type(uint256).max);
        uint256 returned = redemptionVault.redeemInstant(address(usdc), minted, 0);
        vm.stopPrank();

        assertLe(returned, amountIn, "round trip returned more than it consumed");
    }

    function test_TimelockUpgradesRedemptionVaultAndStatePersists() public {
        vm.prank(alice);
        uint256 requestId = redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);

        RedemptionVault nextImpl = new RedemptionVault();
        _executeViaTimelock(
            address(redemptionVault),
            abi.encodeCall(redemptionVault.upgradeToAndCall, (address(nextImpl), ""))
        );

        assertEq(redemptionVault.tokensProvider(), treasury);
        assertEq(redemptionVault.getRequest(requestId).amountWad, 10_000e18);

        vm.prank(alice);
        redemptionVault.cancelRequest(requestId);
        assertEq(token.balanceOf(address(redemptionVault)), 0);
    }

    /// @dev Escrow is visible as an ERC-20 balance, which is what makes the "escrow >= sum of
    ///      pending" invariant checkable from outside.
    function test_EscrowIsVisibleAsAnErc20Balance() public {
        vm.prank(alice);
        redemptionVault.redeemRequest(address(usdc), 10_000e18, 0);
        assertEq(IERC20(address(token)).balanceOf(address(redemptionVault)), 10_000e18);
    }
}
