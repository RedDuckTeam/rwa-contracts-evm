// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";
import {PlatformHandler} from "../helpers/PlatformHandler.sol";

/// @dev Unit tests check what happens on a chosen path; these check what cannot happen on any
///      path. The properties chosen are the ones where a violation means user funds are wrong,
///      not restatements of ERC-20 arithmetic.
contract PlatformInvariantsTest is StdInvariant, PlatformFixture {
    PlatformHandler internal handler;

    address internal carol = makeAddr("carol");

    function setUp() public {
        _deployPlatform();

        _grantOperational(Roles.PAUSER_ROLE, pauser);
        _grantOperational(Roles.UNPAUSER_ROLE, unpauser);

        // A cap the run genuinely REACHES. Measured, not guessed: 32 calls of at most 200k each
        // mint roughly 1.0-1.15M, so 2M was ~2x out of reach and deleting the guard the
        // supply-cap invariant watches left it passing.
        vm.prank(vaultAdmin);
        depositVault.setMaxSupplyCapWad(400_000e18);

        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < actors.length; ++i) {
            _fundWithUsdc(actors[i], 5_000_000e6);
            usdt.mint(actors[i], 5_000_000e6);
            vm.startPrank(actors[i]);
            token.approve(address(redemptionVault), type(uint256).max);
            usdt.approve(address(depositVault), type(uint256).max);
            vm.stopPrank();
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

        targetContract(address(handler));
    }

    /// @dev Less means an open request cannot be honoured; more means an instant deposit left
    ///      funds behind instead of forwarding them, turning the vault into an unaccounted pot.
    function invariant_DepositVaultHoldsExactlyItsOpenEscrow() public view {
        assertEq(
            usdc.balanceOf(address(depositVault)),
            handler.pendingDepositEscrowTokens(address(usdc)),
            "USDC balance diverged from open USDC escrow"
        );
        // The awkward stablecoin included: its own blacklist is what makes a refund fail,
        // leaving escrow behind under a request that stays Pending.
        assertEq(
            usdt.balanceOf(address(depositVault)),
            handler.pendingDepositEscrowTokens(address(usdt)),
            "USDT balance diverged from open USDT escrow"
        );
    }

    /// @dev A shortfall means a cancellation could not be honoured; a surplus means a settled
    ///      redemption failed to burn.
    function invariant_RedemptionVaultHoldsExactlyItsOpenEscrow() public view {
        assertEq(
            token.balanceOf(address(redemptionVault)),
            handler.pendingRedemptionEscrowWad(),
            "redemption vault balance diverged from its open escrow"
        );
    }

    function invariant_SupplyNeverExceedsTheCap() public view {
        assertLe(token.totalSupply(), depositVault.maxSupplyCapWad(), "supply cap breached");
    }

    /// @dev The HONEST form of the guarantee: the bucket is a calendar day, so a rolling 24h
    ///      window can see up to 2x — deviation #3, and the reason FORKING.md tells forks to
    ///      size against the 2x.
    function invariant_DailyInstantVolumeStaysWithinTheBucket() public view {
        uint256 today = block.timestamp / 1 days;
        assertLe(
            handler.depositSpentPerDay(today),
            depositVault.instantDailyLimitWad(),
            "instant deposits exceeded the daily bucket"
        );
        assertLe(
            handler.redemptionSpentPerDay(today),
            redemptionVault.instantDailyLimitWad(),
            "instant redemptions exceeded the daily bucket"
        );
    }

    /// @dev The vaults are conduits: payment-token liquidity lives with the treasury.
    function invariant_RedemptionVaultNeverAccumulatesPaymentTokens() public view {
        assertEq(
            usdc.balanceOf(address(redemptionVault)),
            0,
            "redemption vault retained payment tokens"
        );
    }

    /// @dev A STEADY-STATE assertion: nothing in the handler mutates these bindings, and nothing
    ///      could usefully — they are administered by DEFAULT_ADMIN. What this pins is that no
    ///      ordinary operation disturbs them.
    ///
    ///      That the boundary is operational rather than contract-enforced is pinned instead by
    ///      `AccessRegistryTest.test_MintAndBurnBoundaryIsOperationalNotEnforced`; it cannot be
    ///      shown here, because invariants are evaluated BETWEEN calls and a handler that
    ///      granted and restored within one call would mutate nothing observable.
    function invariant_RoleBoundariesHold() public view {
        assertTrue(registry.hasRole(Roles.MINTER_ROLE, address(depositVault)));
        assertFalse(registry.hasRole(Roles.BURNER_ROLE, address(depositVault)));
        assertTrue(registry.hasRole(Roles.BURNER_ROLE, address(redemptionVault)));
        assertFalse(registry.hasRole(Roles.MINTER_ROLE, address(redemptionVault)));

        assertEq(registry.getRoleMemberCount(Roles.REFUND_VAULT_ROLE), 1);
        assertEq(registry.getRoleMember(Roles.REFUND_VAULT_ROLE, 0), address(redemptionVault));
        assertEq(registry.getRoleMemberCount(Roles.ENFORCER_ROLE), 0);
    }

    /// @dev Only that the runner entered the handler, which IS structurally guaranteed.
    ///      Anything stronger is not: an earlier version asserted `moneyMovingCalls > 0` per
    ///      sequence, but the handler also contains actions that deliberately SUPPRESS money
    ///      movement, so a suppressor-heavy draw legitimately moves nothing and the guard failed
    ///      on ~half of all runs. A coin-flip red suite is worse than the vacuity it replaced —
    ///      it trains everyone to re-run until green.
    ///
    ///      Liveness is asserted DETERMINISTICALLY in `HandlerSmoke.t.sol` instead.
    function afterInvariant() public view {
        assertGt(handler.totalCalls(), 0, "the runner never entered the handler");
    }
}
