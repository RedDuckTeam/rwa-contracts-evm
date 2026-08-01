// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {DepositVault} from "../../contracts/vaults/DepositVault.sol";
import {ManageableVault} from "../../contracts/vaults/ManageableVault.sol";
import {RedemptionVault} from "../../contracts/vaults/RedemptionVault.sol";
import {RwaTokenTester} from "../../contracts/testers/RwaTokenTester.sol";
import {AccessRegistry} from "../../contracts/access/AccessRegistry.sol";
import {Roles} from "../../contracts/access/Roles.sol";
import {ComplianceRegistry} from "../../contracts/compliance/ComplianceRegistry.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockUSDT} from "../../contracts/mocks/MockUSDT.sol";

/// @dev Every entry point bounds its inputs into the plausible range and swallows reverts: the
///      invariants are statements about what the system does when operations SUCCEED, and a
///      fuzzer that mostly generated rejected calls would report green while exercising
///      nothing. Time advances in small random steps so the UTC-day bucket is crossed
///      naturally rather than only at contrived boundaries.
contract PlatformHandler is CommonBase, StdCheats, StdUtils {
    /// @dev The handler reaches into compliance, pauses and the sweep path as well as the money
    ///      flows. An earlier version touched only USDC deposits and redemptions, which left the
    ///      `refundBlocked` -> `Swept` machine unreachable by the fuzzer.
    struct Wiring {
        DepositVault depositVault;
        RedemptionVault redemptionVault;
        RwaTokenTester token;
        MockERC20 usdc;
        MockUSDT usdt;
        ComplianceRegistry compliance;
        AccessRegistry registry;
        address treasury;
        address requestOperator;
        address aggregator;
        address feedOperator;
        address blacklistOperator;
        address pauser;
        address unpauser;
        address timelock;
        address admin;
    }

    DepositVault private immutable DEPOSIT_VAULT;
    RedemptionVault private immutable REDEMPTION_VAULT;
    RwaTokenTester private immutable TOKEN;
    MockERC20 private immutable USDC;
    MockUSDT private immutable USDT;
    ComplianceRegistry private immutable COMPLIANCE;
    AccessRegistry private immutable REGISTRY;
    address private immutable TREASURY;
    address private immutable REQUEST_OPERATOR;
    address private immutable AGGREGATOR;
    address private immutable FEED_OPERATOR;
    address private immutable BLACKLIST_OPERATOR;
    address private immutable PAUSER;
    address private immutable UNPAUSER;
    address private immutable TIMELOCK;
    address private immutable ADMIN;

    address[3] private actors;

    uint256[] public depositRequestIds;
    uint256[] public redemptionRequestIds;

    /// @dev Instant volume charged against each UTC day, mirrored off-chain.
    mapping(uint256 utcDay => uint256 spentWad) public depositSpentPerDay;
    mapping(uint256 utcDay => uint256 spentWad) public redemptionSpentPerDay;

    uint256 public successfulCalls;

    /// @dev Distinguishes "the handler was never targeted" from "every action reverted".
    uint256 public totalCalls;

    /// @dev An invariant that never binds is not evidence: deleting the guard it watches would
    ///      leave it passing. Counting rejections turns "was never violated" into "was tested
    ///      and held".
    uint256 public supplyCapRejections;

    uint256 public dailyLimitRejections;

    /// @dev Separate from `successfulCalls`, which `passTime` alone can satisfy: a run where no
    ///      deposit, redemption or refund ever landed would otherwise look alive.
    uint256 public moneyMovingCalls;

    constructor(Wiring memory w, address[3] memory actors_) {
        DEPOSIT_VAULT = w.depositVault;
        REDEMPTION_VAULT = w.redemptionVault;
        TOKEN = w.token;
        USDC = w.usdc;
        USDT = w.usdt;
        COMPLIANCE = w.compliance;
        REGISTRY = w.registry;
        TREASURY = w.treasury;
        REQUEST_OPERATOR = w.requestOperator;
        AGGREGATOR = w.aggregator;
        FEED_OPERATOR = w.feedOperator;
        BLACKLIST_OPERATOR = w.blacklistOperator;
        PAUSER = w.pauser;
        UNPAUSER = w.unpauser;
        TIMELOCK = w.timelock;
        ADMIN = w.admin;
        actors = actors_;
    }

    /// @dev Records WHICH guard turned a call away, so the invariants can assert the guards
    ///      actually bound rather than merely that nothing broke.
    function _classifyRejection(bytes memory reason) private {
        if (reason.length < 4) return;
        bytes4 selector = bytes4(reason);
        if (selector == DepositVault.MaxSupplyCapExceeded.selector) ++supplyCapRejections;
        if (selector == ManageableVault.DailyLimitExceeded.selector) ++dailyLimitRejections;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev `actors[0]` is deliberately excluded: suppressing every actor at once produces long
    ///      stretches where no money can move, starving the campaign of the states the
    ///      invariants are about. The suppression paths still fire against the other two.
    function _suppressibleActor(uint256 seed) private view returns (address) {
        return actors[1 + (seed % (actors.length - 1))];
    }

    function _today() private view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function depositInstant(uint256 actorSeed, uint256 amountSeed) external {
        ++totalCalls;
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1_000e6, 200_000e6);

        uint256 supplyBefore = TOKEN.totalSupply();
        vm.prank(actor);
        try DEPOSIT_VAULT.depositInstant(address(USDC), amount, 0) {
            ++moneyMovingCalls;
            depositSpentPerDay[_today()] += TOKEN.totalSupply() - supplyBefore;
            ++successfulCalls;
        } catch (bytes memory reason) {
            _classifyRejection(reason);
        }
    }

    function redeemInstant(uint256 actorSeed, uint256 amountSeed) external {
        ++totalCalls;
        address actor = _actor(actorSeed);
        uint256 balance = TOKEN.balanceOf(actor);
        if (balance < 100e18) return;
        uint256 amount = bound(amountSeed, 100e18, balance);

        vm.prank(actor);
        try REDEMPTION_VAULT.redeemInstant(address(USDC), amount, 0) {
            ++moneyMovingCalls;
            redemptionSpentPerDay[_today()] += amount;
            ++successfulCalls;
        } catch {}
    }

    function depositRequest(uint256 actorSeed, uint256 amountSeed) external {
        ++totalCalls;
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1_000e6, 200_000e6);

        vm.prank(actor);
        try DEPOSIT_VAULT.depositRequest(address(USDC), amount, 0) returns (uint256 requestId) {
            depositRequestIds.push(requestId);
            ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    function redeemRequest(uint256 actorSeed, uint256 amountSeed) external {
        ++totalCalls;
        address actor = _actor(actorSeed);
        uint256 balance = TOKEN.balanceOf(actor);
        if (balance < 100e18) return;
        uint256 amount = bound(amountSeed, 100e18, balance);

        vm.prank(actor);
        try REDEMPTION_VAULT.redeemRequest(address(USDC), amount, 0) returns (uint256 requestId) {
            redemptionRequestIds.push(requestId);
            ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    function approveDepositRequest(uint256 indexSeed) external {
        ++totalCalls;
        if (depositRequestIds.length == 0) return;
        uint256 requestId = depositRequestIds[indexSeed % depositRequestIds.length];

        vm.prank(REQUEST_OPERATOR);
        try DEPOSIT_VAULT.approveDepositRequest(requestId, 1e18) {
            ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    function approveRedeemRequest(uint256 indexSeed) external {
        ++totalCalls;
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[indexSeed % redemptionRequestIds.length];

        vm.prank(REQUEST_OPERATOR);
        try REDEMPTION_VAULT.approveRedeemRequest(requestId, 1e18) {
            ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    function cancelDepositRequest(uint256 indexSeed) external {
        ++totalCalls;
        if (depositRequestIds.length == 0) return;
        uint256 requestId = depositRequestIds[indexSeed % depositRequestIds.length];
        address owner = DEPOSIT_VAULT.getRequest(requestId).owner;

        vm.prank(owner);
        try DEPOSIT_VAULT.cancelRequest(requestId) {
            // `cancelRequest` does NOT revert when the payment token refuses the refund: that
            // path completes successfully and moves nothing, which is what `RefundBlocked`
            // exists to signal.
            if (!DEPOSIT_VAULT.getRequest(requestId).refundBlocked) ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    function rejectRedeemRequest(uint256 indexSeed) external {
        ++totalCalls;
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[indexSeed % redemptionRequestIds.length];

        vm.prank(REQUEST_OPERATOR);
        try REDEMPTION_VAULT.rejectRequest(requestId) {
            // See {cancelDepositRequest}: a blocked refund completes without moving money.
            if (!REDEMPTION_VAULT.getRequest(requestId).refundBlocked) ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    /// @dev The aggregator and the operator are CONSTRUCTOR values, not parameters. As
    ///      fuzzer-controlled arguments they were filled with random addresses, so the re-post
    ///      silently never happened, the feed aged past its 72h window, and every priced call
    ///      began reverting — leaving every invariant vacuously true.
    function passTime(uint256 secondsSeed, uint256 navSeed) external {
        ++totalCalls;
        uint256 step = bound(secondsSeed, 1 hours + 1, 10 hours);
        vm.warp(block.timestamp + step);

        // +/- up to 1%, the deviation cap, expressed in the feed's 8 decimals.
        int256 delta = int256(bound(navSeed, 0, 2e6)) - 1e6;
        int256 nextAnswer = 1e8 + delta;

        vm.prank(FEED_OPERATOR);
        (bool ok, ) = AGGREGATOR.call(
            abi.encodeWithSignature("setRoundDataSafe(int256)", nextAnswer)
        );
        if (ok) ++successfulCalls;
    }

    /// @dev Blacklisting mid-run is what makes the refund carve-out reachable: an exit the
    ///      compliance layer would otherwise stop must still return escrow.
    function toggleBlacklist(uint256 actorSeed) external {
        ++totalCalls;
        address actor = _suppressibleActor(actorSeed);

        // Read the status BEFORE pranking. `vm.prank` applies to the next external call, and an
        // argument that is itself an external call consumes it — the toggle then ran as the
        // handler, which holds no role, and failed silently inside the try/catch. This action
        // was inert for the entire campaign.
        bool blacklisted = COMPLIANCE.isBlacklisted(actor);

        vm.prank(BLACKLIST_OPERATOR);
        try COMPLIANCE.setBlacklisted(actor, !blacklisted) {
            ++successfulCalls;
        } catch {}
    }

    /// @dev If an invariant about escrow solvency can be broken by a pause, this finds it.
    function toggleTransferPause() external {
        ++totalCalls;
        bool paused = TOKEN.isOperationPaused(Roles.OP_TRANSFER);

        if (paused) {
            vm.prank(UNPAUSER);
            try TOKEN.unpauseOperation(Roles.OP_TRANSFER) {
                ++successfulCalls;
            } catch {}
        } else {
            vm.prank(PAUSER);
            try TOKEN.pauseOperation(Roles.OP_TRANSFER) {
                ++successfulCalls;
            } catch {}
        }
    }

    /// @dev The stablecoin's own blacklist is the ONLY way to reach `refundBlocked`. Without
    ///      this the `Swept` machine is unreachable by the fuzzer.
    function depositInstantUsdt(uint256 actorSeed, uint256 amountSeed) external {
        ++totalCalls;
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1_000e6, 100_000e6);

        uint256 supplyBefore = TOKEN.totalSupply();
        vm.prank(actor);
        try DEPOSIT_VAULT.depositInstant(address(USDT), amount, 0) {
            // Mirrored into the SAME ghost as the USDC path: the contract charges one bucket
            // for both, so tracking only one leaves the invariant unable to bind.
            depositSpentPerDay[_today()] += TOKEN.totalSupply() - supplyBefore;
            ++moneyMovingCalls;
            ++successfulCalls;
        } catch (bytes memory reason) {
            _classifyRejection(reason);
        }
    }

    /// @dev A USDT request that the stablecoin can later refuse to refund.
    function depositRequestUsdt(uint256 actorSeed, uint256 amountSeed) external {
        ++totalCalls;
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1_000e6, 100_000e6);

        vm.prank(actor);
        try DEPOSIT_VAULT.depositRequest(address(USDT), amount, 0) returns (uint256 requestId) {
            depositRequestIds.push(requestId);
            ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    function toggleStablecoinBlock(uint256 actorSeed) external {
        ++totalCalls;
        address actor = _suppressibleActor(actorSeed);
        USDT.setBlocked(actor, !USDT.isBlocked(actor));
        ++successfulCalls;
    }

    /// @dev The sweep is CRITICAL_CONFIG, so it is pranked as the timelock — the only holder.
    function sweepBlockedRefund(uint256 indexSeed) external {
        ++totalCalls;
        if (depositRequestIds.length == 0) return;
        uint256 requestId = depositRequestIds[indexSeed % depositRequestIds.length];

        vm.prank(TIMELOCK);
        try DEPOSIT_VAULT.sweepBlockedRefund(requestId) {
            ++moneyMovingCalls;
            ++successfulCalls;
        } catch {}
    }

    /// @dev Per token, not aggregated. The handler drives two stablecoins, and summing them
    ///      would compare a mixed total against a single token's balance — an invariant that
    ///      fails for a reason that is purely an artefact of the test.
    function pendingDepositEscrowTokens(address paymentToken) external view returns (uint256 total) {
        for (uint256 i; i < depositRequestIds.length; ++i) {
            ManageableVault.Request memory request = DEPOSIT_VAULT.getRequest(depositRequestIds[i]);
            if (
                request.status == ManageableVault.RequestStatus.Pending &&
                request.paymentToken == paymentToken
            ) {
                // Escrow is stored in WAD; the vault holds it in the token's own decimals.
                total += request.amountWad / 10 ** (18 - request.decimalsPinned);
            }
        }
    }

    function pendingRedemptionEscrowWad() external view returns (uint256 total) {
        for (uint256 i; i < redemptionRequestIds.length; ++i) {
            ManageableVault.Request memory request = REDEMPTION_VAULT.getRequest(
                redemptionRequestIds[i]
            );
            if (request.status == ManageableVault.RequestStatus.Pending) {
                total += request.amountWad;
            }
        }
    }

    function depositRequestCount() external view returns (uint256) {
        return depositRequestIds.length;
    }

    function redemptionRequestCount() external view returns (uint256) {
        return redemptionRequestIds.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }
}
