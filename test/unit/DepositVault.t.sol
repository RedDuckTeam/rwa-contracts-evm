// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {WithAccessRegistry} from "../../contracts/access/WithAccessRegistry.sol";
import {ComplianceRegistry} from "../../contracts/compliance/ComplianceRegistry.sol";
import {DecimalsConverter} from "../../contracts/libraries/DecimalsConverter.sol";
import {DataFeed} from "../../contracts/oracle/DataFeed.sol";
import {OperationPausable} from "../../contracts/pause/OperationPausable.sol";
import {DepositVault} from "../../contracts/vaults/DepositVault.sol";
import {ManageableVault} from "../../contracts/vaults/ManageableVault.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract DepositVaultTest is PlatformFixture {
    function setUp() public {
        _deployPlatform();
        _fundWithUsdc(alice, 1_000_000e6);
        _fundWithUsdc(bob, 1_000_000e6);
    }

    function test_InstantDepositMintsAtTheLiveRateAndForwardsFunds() public {
        // 10 000 USDC in, 1% fee, NAV 1.00 -> 9 900 wBOND out.
        vm.prank(alice);
        uint256 minted = depositVault.depositInstant(address(usdc), 10_000e6, 0);

        assertEq(minted, 9_900e18);
        assertEq(token.balanceOf(alice), 9_900e18);

        // Nothing rests in the vault: fee and body leave in the same transaction.
        assertEq(usdc.balanceOf(address(depositVault)), 0);
        assertEq(usdc.balanceOf(feeCollector), 100e6);
        assertEq(usdc.balanceOf(treasury) - 10_000_000e6, 9_900e6);
    }

    function test_InstantDepositRespectsMinOut() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.SlippageExceeded.selector, 9_900e18, 10_000e18)
        );
        depositVault.depositInstant(address(usdc), 10_000e6, 10_000e18);
    }

    function test_InstantDepositHonoursAFeeWaiver() public {
        vm.prank(vaultAdmin);
        depositVault.setFeeWaiver(alice, true);
        assertTrue(depositVault.isFeeWaived(alice));

        vm.prank(alice);
        uint256 minted = depositVault.depositInstant(address(usdc), 10_000e6, 0);

        assertEq(minted, 10_000e18);
        assertEq(usdc.balanceOf(feeCollector), 0);
    }

    function test_PerTokenFeeStacksOnTopOfTheVaultFee() public {
        vm.prank(vaultAdmin);
        depositVault.updatePaymentToken(address(usdc), true, 200, type(uint256).max);

        // 1% vault fee + 2% token fee = 3%.
        vm.prank(alice);
        uint256 minted = depositVault.depositInstant(address(usdc), 10_000e6, 0);

        assertEq(minted, 9_700e18);
        assertEq(usdc.balanceOf(feeCollector), 300e6);
    }

    /// @dev The higher minimum applies only to a genuine first deposit.
    function test_FirstDepositMinimumAppliesOnceThenRelaxes() public {
        assertFalse(depositVault.hasDeposited(alice));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManageableVault.AmountBelowMinimum.selector,
                500e18,
                MIN_FIRST_AMOUNT_WAD
            )
        );
        depositVault.depositInstant(address(usdc), 500e6, 0);

        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 1_000e6, 0);
        assertTrue(depositVault.hasDeposited(alice));

        // The ordinary minimum now applies.
        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 100e6, 0);
    }

    /// @dev Someone who already holds the token, say by transfer, is not a first-time depositor,
    ///      so re-imposing the entry minimum on them would be arbitrary.
    function test_ExistingHolderIsNotTreatedAsAFirstDepositor() public {
        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 1_000e6, 0);

        vm.prank(alice);
        token.transfer(bob, 500e18);

        vm.prank(bob);
        depositVault.depositInstant(address(usdc), 100e6, 0);
        assertGt(token.balanceOf(bob), 500e18);
    }

    function test_MinimumWaiverBypassesBothMinimums() public {
        vm.prank(vaultAdmin);
        depositVault.setMinAmountWaiver(alice, true);

        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 1e6, 0);
        assertGt(token.balanceOf(alice), 0);
    }

    function test_RevertWhen_DailyLimitIsExhausted() public {
        vm.prank(vaultAdmin);
        depositVault.setInstantDailyLimitWad(10_000e18);

        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 10_000e6, 0); // mints 9 900
        assertEq(depositVault.spentTodayWad(), 9_900e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.DailyLimitExceeded.selector, 990e18, 100e18)
        );
        depositVault.depositInstant(address(usdc), 1_000e6, 0);
    }

    /// @dev The registered deviation, asserted rather than glossed over: the bucket is a UTC
    ///      CALENDAR day, so a full limit spent late on one day and again early on the next puts
    ///      up to 2x through a single rolling 24h window.
    function test_CalendarBucketAllowsUpTo2xInARolling24hWindow() public {
        vm.prank(vaultAdmin);
        depositVault.setInstantDailyLimitWad(10_000e18);

        // Land near the end of a UTC day.
        uint256 dayStart = (block.timestamp / 1 days) * 1 days;
        vm.warp(dayStart + 1 days - 1 hours);

        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 10_000e6, 0);

        // Two hours later the calendar day has rolled over and the budget is fresh.
        vm.warp(block.timestamp + 2 hours);
        assertEq(depositVault.spentTodayWad(), 0);

        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 10_000e6, 0);

        assertEq(token.balanceOf(alice), 19_800e18); // ~2x the limit within 3 hours
    }

    function test_RevertWhen_SupplyCapWouldBeExceeded() public {
        vm.prank(vaultAdmin);
        depositVault.setMaxSupplyCapWad(5_000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DepositVault.MaxSupplyCapExceeded.selector, 9_900e18, 5_000e18)
        );
        depositVault.depositInstant(address(usdc), 10_000e6, 0);
    }

    function test_RevertWhen_CallerIsNotGreenlisted() public {
        vm.prank(complianceAdmin);
        compliance.setGreenlistEnabled(true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.NotGreenlisted.selector, alice));
        depositVault.depositInstant(address(usdc), 10_000e6, 0);

        _greenlist(alice);
        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 10_000e6, 0);
    }

    function test_RevertWhen_CallerIsBlacklistedOrSanctioned() public {
        _blacklist(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        depositVault.depositInstant(address(usdc), 10_000e6, 0);

        sanctions.setSanctioned(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.SanctionedAccount.selector, bob));
        depositVault.depositInstant(address(usdc), 10_000e6, 0);
    }

    function test_RevertWhen_OperationIsPaused() public {
        _grantOperational(Roles.PAUSER_ROLE, pauser);
        vm.prank(pauser);
        depositVault.pauseOperation(Roles.OP_DEPOSIT_INSTANT);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OperationPausable.OperationIsPaused.selector,
                Roles.OP_DEPOSIT_INSTANT
            )
        );
        depositVault.depositInstant(address(usdc), 10_000e6, 0);

        // The request flow is a separate switch and is untouched.
        vm.prank(alice);
        depositVault.depositRequest(address(usdc), 10_000e6, 0);
    }

    /// @dev A dead feed must stop issuance rather than price it at a stale NAV.
    function test_RevertWhen_FeedIsUnhealthy() public {
        vm.warp(block.timestamp + HEALTHY_DIFF + 1);

        vm.prank(alice);
        vm.expectRevert();
        depositVault.depositInstant(address(usdc), 10_000e6, 0);
    }

    function test_RevertWhen_TokenIsUnknownOrDisabled() public {
        MockERC20 stranger = new MockERC20("Stranger", "STR", 18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.TokenNotConfigured.selector, address(stranger))
        );
        depositVault.depositInstant(address(stranger), 1e18, 0);

        vm.prank(vaultAdmin);
        depositVault.updatePaymentToken(address(usdc), false, 0, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.TokenDisabled.selector, address(usdc))
        );
        depositVault.depositInstant(address(usdc), 10_000e6, 0);
    }

    function test_RevertWhen_TokenAllowanceIsExhausted() public {
        vm.prank(vaultAdmin);
        depositVault.updatePaymentToken(address(usdc), true, 0, 5_000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManageableVault.TokenAllowanceExceeded.selector,
                address(usdc),
                10_000e18,
                5_000e18
            )
        );
        depositVault.depositInstant(address(usdc), 10_000e6, 0);

        vm.prank(alice);
        depositVault.depositInstant(address(usdc), 5_000e6, 0);
        assertEq(depositVault.paymentTokenConfig(address(usdc)).remainingAllowanceWad, 0);
    }

    function test_RevertWhen_AmountIsZero() public {
        vm.prank(alice);
        vm.expectRevert(ManageableVault.ZeroAmount.selector);
        depositVault.depositInstant(address(usdc), 0, 0);
    }

    /// @dev Credit follows the balance DELTA: crediting the request would mint NAV tokens
    ///      against value the vault never received.
    function test_FeeOnTransferTokenIsCreditedByActualDelta() public {
        usdt.setTransferFeeBps(100); // the token withholds 1%
        usdt.mint(alice, 100_000e6);
        vm.prank(alice);
        usdt.approve(address(depositVault), type(uint256).max);

        vm.prank(alice);
        uint256 minted = depositVault.depositInstant(address(usdt), 10_000e6, 0);

        // 10 000 requested -> 9 900 delivered -> 1% vault fee -> 9 801 minted.
        assertEq(minted, 9_801e18);
        assertEq(usdt.balanceOf(address(depositVault)), 0);
    }

    /// @dev USDT's `approve` returns nothing; `SafeERC20` is what makes it usable.
    function test_NonStandardApproveTokenWorks() public {
        usdt.mint(alice, 100_000e6);
        vm.prank(alice);
        usdt.approve(address(depositVault), type(uint256).max);

        vm.prank(alice);
        depositVault.depositInstant(address(usdt), 10_000e6, 0);
        assertEq(token.balanceOf(alice), 9_900e18);
    }

    function test_RevertWhen_PaymentTokenHasMoreThan18Decimals() public {
        MockERC20 weird = new MockERC20("Weird", "WRD", 19);

        vm.prank(vaultAdmin);
        vm.expectRevert(abi.encodeWithSelector(DecimalsConverter.DecimalsTooHigh.selector, uint8(19)));
        depositVault.addPaymentToken(address(weird), 0, type(uint256).max);
    }

    function test_RequestEscrowsAndPinsConfiguration() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 9_000e18);

        ManageableVault.Request memory request = depositVault.getRequest(requestId);
        assertEq(request.owner, alice);
        assertEq(request.paymentToken, address(usdc));
        assertEq(request.amountWad, 10_000e18);
        assertEq(request.feeBpsPinned, INSTANT_FEE_BPS);
        assertEq(request.decimalsPinned, 6);
        assertEq(request.minOutWad, 9_000e18);
        assertEq(uint8(request.status), uint8(ManageableVault.RequestStatus.Pending));

        // The money is genuinely escrowed here, not forwarded.
        assertEq(usdc.balanceOf(address(depositVault)), 10_000e6);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Changing the fee after submission must not change the economics of a request the
    ///      user already committed to.
    function test_ApprovalUsesThePinnedFeeNotTheCurrentOne() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(vaultAdmin);
        depositVault.setInstantFeeBps(500);

        vm.prank(requestOperator);
        uint256 minted = depositVault.approveDepositRequest(requestId, 1e18);

        assertEq(minted, 9_900e18); // 1%, as pinned — not 5%
    }

    function test_ApprovalWithinToleranceSettles() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        // 1% away from the oracle's 1.00 — exactly at the tolerance.
        vm.prank(requestOperator);
        uint256 minted = depositVault.approveDepositRequest(requestId, 1.01e18);

        assertEq(token.balanceOf(alice), minted);
        assertEq(usdc.balanceOf(address(depositVault)), 0);
        assertEq(
            uint8(depositVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Approved)
        );
    }

    function test_RevertWhen_OperatorRateIsOutsideTolerance() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(requestOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManageableVault.RateOutsideTolerance.selector,
                1.02e18,
                1e18,
                VARIATION_TOLERANCE_BPS
            )
        );
        depositVault.approveDepositRequest(requestId, 1.02e18);
    }

    function test_RevertWhen_ApprovalWouldBreachMinOut() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 9_950e18);

        vm.prank(requestOperator);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.SlippageExceeded.selector, 9_900e18, 9_950e18)
        );
        depositVault.approveDepositRequest(requestId, 1e18);
    }

    function test_RejectReturnsTheEscrowInFull() public {
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(requestOperator);
        depositVault.rejectRequest(requestId);

        assertEq(usdc.balanceOf(alice), balanceBefore);
        assertEq(
            uint8(depositVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Rejected)
        );
    }

    function test_CancelReturnsTheEscrowInFull() public {
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        assertEq(usdc.balanceOf(alice), balanceBefore);
        assertEq(
            uint8(depositVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Cancelled)
        );
    }

    /// @dev Exits must survive the conditions that make entry unsafe: a paused operation, an
    ///      unhealthy feed, a mid-flight blacklist.
    function test_ExitsWorkWhilePausedUnhealthyAndBlacklisted() public {
        vm.prank(alice);
        uint256 rejected = depositVault.depositRequest(address(usdc), 10_000e6, 0);
        vm.prank(bob);
        uint256 cancelled = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        _grantOperational(Roles.PAUSER_ROLE, pauser);
        vm.prank(pauser);
        depositVault.pauseOperation(Roles.OP_DEPOSIT_REQUEST);

        vm.warp(block.timestamp + HEALTHY_DIFF + 1); // the feed is now stale
        _blacklist(alice);

        vm.prank(requestOperator);
        depositVault.rejectRequest(rejected);

        vm.prank(bob);
        depositVault.cancelRequest(cancelled);

        assertEq(
            uint8(depositVault.getRequest(rejected).status),
            uint8(ManageableVault.RequestStatus.Rejected)
        );
        assertEq(
            uint8(depositVault.getRequest(cancelled).status),
            uint8(ManageableVault.RequestStatus.Cancelled)
        );
    }

    /// @dev Delisting a token closes new business without stranding existing escrow.
    function test_ExitsWorkAfterTheTokenIsDelisted() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(vaultAdmin);
        depositVault.updatePaymentToken(address(usdc), false, 0, type(uint256).max);

        vm.prank(alice);
        depositVault.cancelRequest(requestId);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    function test_RevertWhen_ARequestIsResolvedTwice() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(requestOperator);
        depositVault.approveDepositRequest(requestId, 1e18);

        vm.prank(requestOperator);
        vm.expectRevert(abi.encodeWithSelector(ManageableVault.RequestNotPending.selector, requestId));
        depositVault.approveDepositRequest(requestId, 1e18);

        vm.prank(requestOperator);
        vm.expectRevert(abi.encodeWithSelector(ManageableVault.RequestNotPending.selector, requestId));
        depositVault.rejectRequest(requestId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ManageableVault.RequestNotPending.selector, requestId));
        depositVault.cancelRequest(requestId);
    }

    function test_RevertWhen_SomeoneElseCancelsYourRequest() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.NotRequestOwner.selector, requestId, bob)
        );
        depositVault.cancelRequest(requestId);
    }

    function test_RevertWhen_UnknownRequestIsTouched() public {
        vm.prank(requestOperator);
        vm.expectRevert(abi.encodeWithSelector(ManageableVault.RequestNotPending.selector, 999));
        depositVault.rejectRequest(999);
    }

    function test_RevertWhen_NonOperatorApprovesOrRejects() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.REQUEST_OPERATOR_ROLE,
                admin
            )
        );
        depositVault.approveDepositRequest(requestId, 1e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.REQUEST_OPERATOR_ROLE,
                alice
            )
        );
        depositVault.rejectRequest(requestId);
    }

    function _blockedUsdtRequest() internal returns (uint256 requestId) {
        usdt.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdt.approve(address(depositVault), type(uint256).max);
        requestId = depositVault.depositRequest(address(usdt), 10_000e6, 0);
        vm.stopPrank();

        // The stablecoin's own blacklist now refuses to move funds to Alice.
        usdt.setBlocked(alice, true);
    }

    /// @dev The one path that completes successfully without moving money. The event is the only
    ///      way a monitor tells it apart from an ordinary cancellation.
    function test_CancelRecordsRefundBlockedWhenTheStablecoinRefuses() public {
        uint256 requestId = _blockedUsdtRequest();

        vm.expectEmit(true, true, true, false, address(depositVault));
        emit ManageableVault.RefundBlocked(requestId, alice, address(usdt));
        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        ManageableVault.Request memory request = depositVault.getRequest(requestId);
        assertTrue(request.refundBlocked);
        // Still Pending: the exit has not actually happened.
        assertEq(uint8(request.status), uint8(ManageableVault.RequestStatus.Pending));
        assertEq(usdt.balanceOf(address(depositVault)), 10_000e6);
    }

    /// @dev No privileged action needed: once the block lifts, the user simply cancels again.
    function test_UserCanCancelAgainOnceTheStablecoinUnblocksThem() public {
        uint256 requestId = _blockedUsdtRequest();

        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        usdt.setBlocked(alice, false);

        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        ManageableVault.Request memory request = depositVault.getRequest(requestId);
        assertFalse(request.refundBlocked);
        assertEq(uint8(request.status), uint8(ManageableVault.RequestStatus.Cancelled));
    }

    /// @dev The sweep RETRIES at execution time, so a holder unblocked during the 48h delay gets
    ///      paid: the stale flag alone never confiscates.
    function test_SweepPaysTheOwnerWhenTheRetrySucceeds() public {
        uint256 requestId = _blockedUsdtRequest();
        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        usdt.setBlocked(alice, false); // unblocked while the proposal matures

        uint256 balanceBefore = usdt.balanceOf(alice);
        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.sweepBlockedRefund, (requestId))
        );

        assertEq(usdt.balanceOf(alice) - balanceBefore, 10_000e6);
        assertEq(usdt.balanceOf(blockedFunds), 0);
        assertEq(
            uint8(depositVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Cancelled)
        );
    }

    function test_SweepDivertsFundsOnlyWhenTheRetryFailsAgain() public {
        uint256 requestId = _blockedUsdtRequest();
        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        // Still blocked at execution time.
        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.sweepBlockedRefund, (requestId))
        );

        assertEq(usdt.balanceOf(blockedFunds), 10_000e6);
        assertEq(
            uint8(depositVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Swept)
        );
    }

    /// @dev No retry: on the deposit side the payment token knows nothing of our sanctions list
    ///      and would happily pay them.
    function test_SanctionedOwnerIsSweptWithoutARetry() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        sanctions.setSanctioned(alice, true);

        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.sweepBlockedRefund, (requestId))
        );

        assertEq(usdc.balanceOf(blockedFunds), 10_000e6);
        assertEq(
            uint8(depositVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Swept)
        );
    }

    /// @dev EIP-150 forwards at most 63/64 of available gas to a child frame, so a caller
    ///      supplying a tight limit could otherwise make the inner transfer run out while the
    ///      outer frame survives to record "the token refused" — letting a compromised
    ///      REQUEST_OPERATOR latch `refundBlocked` on every pending request without any token
    ///      having refused anything.
    function test_RevertWhen_ARefundIsAttemptedWithoutEnoughGas() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        uint256 floor = depositVault.MIN_REFUND_GAS();

        vm.prank(requestOperator);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.RefundGasExhausted.selector, requestId)
        );
        // Forwarding exactly the floor guarantees the check sees less: reaching it costs the
        // role check, the reentrancy guard and a storage read.
        depositVault.rejectRequest{gas: floor}(requestId);

        // Untouched: still Pending, and NOT marked sweep-eligible.
        ManageableVault.Request memory request = depositVault.getRequest(requestId);
        assertEq(uint8(request.status), uint8(ManageableVault.RequestStatus.Pending));
        assertFalse(request.refundBlocked, "an under-funded call latched refundBlocked");

        // With a normal budget it resolves as it should.
        vm.prank(requestOperator);
        depositVault.rejectRequest(requestId);
        assertEq(
            uint8(depositVault.getRequest(requestId).status),
            uint8(ManageableVault.RequestStatus.Rejected)
        );
    }

    function test_RevertWhen_SweepingAHealthyRequest() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(ManageableVault.NothingToSweep.selector, requestId));
        depositVault.sweepBlockedRefund(requestId);
    }

    function test_RevertWhen_SweepingTwice() public {
        uint256 requestId = _blockedUsdtRequest();
        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.sweepBlockedRefund, (requestId))
        );

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(ManageableVault.RequestNotPending.selector, requestId));
        depositVault.sweepBlockedRefund(requestId);
    }

    function test_RevertWhen_SweepIsCalledOutsideTheTimelock() public {
        uint256 requestId = _blockedUsdtRequest();
        vm.prank(alice);
        depositVault.cancelRequest(requestId);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                admin
            )
        );
        depositVault.sweepBlockedRefund(requestId);
    }

    /// @dev The hop exists so `SafeERC20`'s revert can be caught; nobody else may call it.
    function test_RevertWhen_RefundHopIsCalledExternally() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        vm.prank(alice);
        vm.expectRevert(ManageableVault.OnlySelf.selector);
        depositVault.performEscrowRefund(requestId);
    }

    /// @dev Why issuance and redemption are separate contracts: a bug on this side cannot
    ///      destroy supply.
    function test_DepositVaultHasMinterButNotBurner() public view {
        assertTrue(registry.hasRole(Roles.MINTER_ROLE, address(depositVault)));
        assertFalse(registry.hasRole(Roles.BURNER_ROLE, address(depositVault)));
        assertFalse(registry.hasRole(Roles.REFUND_VAULT_ROLE, address(depositVault)));
    }

    function test_RevertWhen_ParametersWouldExceedTheirCodedCaps() public {
        uint256 maxFee = depositVault.MAX_INSTANT_FEE_BPS();
        uint256 maxMin = depositVault.MAX_MIN_AMOUNT_WAD();

        vm.startPrank(vaultAdmin);

        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setInstantFeeBps(maxFee + 1);

        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setInstantDailyLimitWad(0);

        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setMinAmounts(maxMin + 1, maxMin + 1);

        // A first-deposit minimum below the ordinary one is incoherent.
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setMinAmounts(1_000e18, 500e18);

        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setMaxSupplyCapWad(0);

        vm.stopPrank();
    }

    /// @dev A guardrail on the operator must not be adjustable by the operator's own admin.
    function test_RevertWhen_VaultAdminTouchesCriticalConfig() public {
        vm.startPrank(vaultAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                vaultAdmin
            )
        );
        depositVault.setVariationToleranceBps(1_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                vaultAdmin
            )
        );
        depositVault.setReceivers(vaultAdmin, vaultAdmin, vaultAdmin);

        vm.stopPrank();
    }

    function test_TimelockAdjustsCriticalConfig() public {
        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.setVariationToleranceBps, (500))
        );
        assertEq(depositVault.variationToleranceBps(), 500);

        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.setReceivers, (bob, bob, bob))
        );
        assertEq(depositVault.tokensReceiver(), bob);

        DataFeed replacement = new DataFeed();
        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.setDataFeed, (address(replacement)))
        );
        assertEq(address(depositVault.dataFeed()), address(replacement));
    }

    function test_RevertWhen_CriticalAddressesWouldBeZero() public {
        vm.startPrank(address(timelock));

        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setReceivers(address(0), feeCollector, blockedFunds);

        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setDataFeed(address(0));

        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setComplianceRegistry(address(0));

        vm.stopPrank();
    }

    function test_RevertWhen_TokenIsRegisteredTwiceOrUpdatedUnknown() public {
        MockERC20 stranger = new MockERC20("Stranger", "STR", 18);

        vm.prank(vaultAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.TokenAlreadyConfigured.selector, address(usdc))
        );
        depositVault.addPaymentToken(address(usdc), 0, type(uint256).max);

        vm.prank(vaultAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(ManageableVault.TokenNotConfigured.selector, address(stranger))
        );
        depositVault.updatePaymentToken(address(stranger), true, 0, type(uint256).max);

        vm.prank(vaultAdmin);
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.addPaymentToken(address(stranger), 501, type(uint256).max);
    }

    function test_PaymentTokenRegistryIsEnumerable() public view {
        address[] memory tokens = depositVault.paymentTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc));
        assertEq(tokens[1], address(usdt));
    }

    function test_RoleGettersDefaultToTheCanonicalConstants() public view {
        assertEq(depositVault.vaultAdminRole(), Roles.VAULT_ADMIN_ROLE);
        assertEq(depositVault.requestOperatorRole(), Roles.REQUEST_OPERATOR_ROLE);
    }

    /// @dev For any amount and fee, the vault keeps nothing and the split sums back to what was
    ///      received.
    function testFuzz_NothingIsRetainedAndTheSplitIsExact(uint96 amountIn, uint16 feeBps) public {
        amountIn = uint96(bound(amountIn, 1_000e6, 500_000e6));
        feeBps = uint16(bound(feeBps, 0, depositVault.MAX_INSTANT_FEE_BPS()));

        vm.prank(vaultAdmin);
        depositVault.setInstantFeeBps(feeBps);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 feeBefore = usdc.balanceOf(feeCollector);

        vm.prank(alice);
        depositVault.depositInstant(address(usdc), amountIn, 0);

        assertEq(usdc.balanceOf(address(depositVault)), 0, "vault retained funds");
        assertEq(
            (usdc.balanceOf(treasury) - treasuryBefore) + (usdc.balanceOf(feeCollector) - feeBefore),
            amountIn,
            "split did not sum back"
        );
    }

    /// @dev Pinned to `ceil` exactly, not `collected >= floor(...)`: `ceil >= floor` holds for
    ///      every input, so the weaker form is a theorem and flipping the contract to
    ///      `Math.Rounding.Floor` — the bug this catches — would leave it passing.
    function testFuzz_FeeRoundingIsExactlyCeiling(uint96 amountIn, uint16 feeBps) public {
        amountIn = uint96(bound(amountIn, 1_000e6, 500_000e6));
        feeBps = uint16(bound(feeBps, 1, depositVault.MAX_INSTANT_FEE_BPS()));

        vm.prank(vaultAdmin);
        depositVault.setInstantFeeBps(feeBps);

        uint256 feeBefore = usdc.balanceOf(feeCollector);
        vm.prank(alice);
        depositVault.depositInstant(address(usdc), amountIn, 0);

        uint256 numerator = uint256(amountIn) * feeBps;
        uint256 expected = numerator / 10_000 + (numerator % 10_000 == 0 ? 0 : 1);
        assertEq(usdc.balanceOf(feeCollector) - feeBefore, expected);
    }

    /// @dev Escrow leaves exactly as it arrived, for any amount and any pinned fee.
    function testFuzz_RejectReturnsExactlyWhatWasEscrowed(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1_000e6, 500_000e6));

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), amountIn, 0);

        vm.prank(requestOperator);
        depositVault.rejectRequest(requestId);

        assertEq(usdc.balanceOf(alice), before);
        assertEq(usdc.balanceOf(address(depositVault)), 0);
    }

    function test_TimelockUpgradesVaultAndStatePersists() public {
        vm.prank(alice);
        uint256 requestId = depositVault.depositRequest(address(usdc), 10_000e6, 0);

        DepositVault nextImpl = new DepositVault();
        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.upgradeToAndCall, (address(nextImpl), ""))
        );

        assertEq(depositVault.getRequest(requestId).amountWad, 10_000e18);
        assertEq(depositVault.maxSupplyCapWad(), MAX_SUPPLY_CAP_WAD);

        vm.prank(alice);
        depositVault.cancelRequest(requestId);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    function test_RevertWhen_NonUpgraderUpgradesVault() public {
        DepositVault nextImpl = new DepositVault();

        vm.prank(vaultAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UPGRADER_ROLE, vaultAdmin)
        );
        depositVault.upgradeToAndCall(address(nextImpl), "");
    }

    function test_EscrowIsVisibleThroughTheErc20Interface() public {
        vm.prank(alice);
        depositVault.depositRequest(address(usdc), 10_000e6, 0);
        assertEq(IERC20(address(usdc)).balanceOf(address(depositVault)), 10_000e6);
    }
}
