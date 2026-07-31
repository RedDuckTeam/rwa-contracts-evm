// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Roles} from "../../contracts/access/Roles.sol";
import {ManageableVault} from "../../contracts/vaults/ManageableVault.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";
import {PlatformHandler} from "../helpers/PlatformHandler.sol";

/// @dev Proves the invariant handler can actually move the system. Without this, a handler whose
///      every call reverted would leave every invariant holding vacuously and the suite
///      reporting green while testing nothing.
contract HandlerSmokeTest is PlatformFixture {
    PlatformHandler internal handler;
    address internal carol = makeAddr("carol");

    function setUp() public {
        _deployPlatform();

        _grantOperational(Roles.PAUSER_ROLE, pauser);
        _grantOperational(Roles.UNPAUSER_ROLE, unpauser);

        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < actors.length; ++i) {
            _fundWithUsdc(actors[i], 5_000_000e6);
            vm.prank(actors[i]);
            token.approve(address(redemptionVault), type(uint256).max);
        }

        handler = new PlatformHandler(
            PlatformHandler.Wiring({
                depositVault: depositVault,
                redemptionVault: redemptionVault,
                token: token,
                usdc: usdc,
                usdt: usdt,
                compliance: compliance,
                registry: registry,
                treasury: treasury,
                requestOperator: requestOperator,
                aggregator: address(aggregator),
                feedOperator: feedOperator,
                blacklistOperator: blacklistOperator,
                pauser: pauser,
                unpauser: unpauser,
                timelock: address(timelock),
                admin: admin
            }),
            actors
        );
    }

    function test_EveryHandlerActionCanSucceed() public {
        handler.depositInstant(0, 50_000e6);
        assertGt(token.balanceOf(alice), 0, "instant deposit never landed");

        handler.depositRequest(1, 50_000e6);
        assertEq(handler.depositRequestCount(), 1, "deposit request never recorded");

        handler.approveDepositRequest(0);
        assertGt(token.balanceOf(bob), 0, "deposit approval never landed");

        handler.redeemInstant(0, 1_000e18);
        handler.redeemRequest(0, 1_000e18);
        assertEq(handler.redemptionRequestCount(), 1, "redemption request never recorded");

        handler.rejectRedeemRequest(0);
        handler.passTime(2 hours, 0);

        assertGt(handler.moneyMovingCalls(), 3, "barely any money moved");
    }

    /// @dev Each action must produce an OBSERVABLE state change. An earlier version asserted a
    ///      call COUNT after six calls, two of which increment unconditionally, so it passed
    ///      even when an action could never succeed.
    function test_ComplianceAndPauseActionsChangeObservableState() public {
        // Suppression targets actors[1..]; actors[0] is reserved so campaigns cannot starve.
        // Asserted here so that reservation stays visible rather than becoming a silent reason
        // these actions appear to do nothing.
        assertFalse(compliance.isBlacklisted(alice), "actors[0] must never be suppressible");
        handler.toggleBlacklist(0);
        assertFalse(compliance.isBlacklisted(alice), "actors[0] was suppressed");
        assertTrue(compliance.isBlacklisted(bob), "toggleBlacklist changed nothing");
        handler.toggleBlacklist(0);
        assertFalse(compliance.isBlacklisted(bob), "toggleBlacklist does not toggle back");

        assertFalse(token.isOperationPaused(Roles.OP_TRANSFER));
        handler.toggleTransferPause();
        assertTrue(token.isOperationPaused(Roles.OP_TRANSFER), "toggleTransferPause did nothing");
        handler.toggleTransferPause();
        assertFalse(token.isOperationPaused(Roles.OP_TRANSFER), "pause does not toggle back");

        assertFalse(usdt.isBlocked(bob));
        handler.toggleStablecoinBlock(0);
        assertTrue(usdt.isBlocked(bob), "toggleStablecoinBlock did nothing");
    }

    /// @dev An invariant that never binds is not evidence: with the cap out of reach, deleting
    ///      the guard entirely leaves `invariant_SupplyNeverExceedsTheCap` passing in every
    ///      campaign. This pins that it is reachable at the cap the invariant fixture uses.
    function test_SupplyCapActuallyRejects() public {
        vm.prank(vaultAdmin);
        depositVault.setMaxSupplyCapWad(400_000e18);

        for (uint256 i; i < 32; ++i) {
            handler.depositInstant(i % 3, 200_000e6);
            handler.passTime(2 hours, i);
        }

        assertGt(handler.supplyCapRejections(), 0, "the supply cap never bound");
        assertLe(token.totalSupply(), 400_000e18);
    }

    /// @dev Same argument for the daily bucket, across BOTH stablecoins: the USDT path charges
    ///      the same bucket, and an earlier handler mirrored only the USDC side — which left the
    ///      invariant unable to bind at all.
    function test_DailyLimitActuallyRejects() public {
        vm.prank(vaultAdmin);
        depositVault.setInstantDailyLimitWad(300_000e18);

        usdt.mint(alice, 5_000_000e6);
        vm.prank(alice);
        usdt.approve(address(depositVault), type(uint256).max);

        for (uint256 i; i < 6; ++i) {
            handler.depositInstant(0, 200_000e6);
            handler.depositInstantUsdt(0, 200_000e6);
        }

        assertGt(handler.dailyLimitRejections(), 0, "the daily bucket never bound");
        assertLe(handler.depositSpentPerDay(block.timestamp / 1 days), 300_000e18);
    }

    /// @dev The full cycle through handler entry points only: escrow in the awkward stablecoin,
    ///      the stablecoin refuses the refund, the request stays Pending, the timelocked sweep
    ///      resolves it.
    function test_BlockedRefundCycleIsReachableThroughTheHandler() public {
        // Driven as `bob`, an actor the handler is allowed to suppress.
        usdt.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdt.approve(address(depositVault), type(uint256).max);

        handler.depositRequestUsdt(1, 50_000e6);
        assertEq(handler.depositRequestCount(), 1, "no USDT request was escrowed");

        handler.toggleStablecoinBlock(0); // the stablecoin now refuses bob
        handler.cancelDepositRequest(0);

        ManageableVault.Request memory request = depositVault.getRequest(1);
        assertTrue(request.refundBlocked, "the blocked refund was never recorded");
        assertEq(uint8(request.status), uint8(ManageableVault.RequestStatus.Pending));

        handler.sweepBlockedRefund(0);
        assertEq(
            uint8(depositVault.getRequest(1).status),
            uint8(ManageableVault.RequestStatus.Swept),
            "the sweep never resolved the request"
        );
    }

    /// @dev Or every priced call in a deep invariant run silently becomes a no-op.
    function test_TimePassingKeepsTheFeedHealthy() public {
        for (uint256 i; i < 40; ++i) {
            handler.passTime(i * 977, i);
        }

        uint256 before = handler.successfulCalls();
        handler.depositInstant(0, 50_000e6);
        assertGt(handler.successfulCalls(), before, "feed went stale during the walk");
    }
}
