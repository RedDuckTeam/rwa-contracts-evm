// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {WithAccessRegistry} from "../../contracts/access/WithAccessRegistry.sol";
import {ComplianceRegistry} from "../../contracts/compliance/ComplianceRegistry.sol";
import {IERC7943} from "../../contracts/interfaces/IERC7943.sol";
import {RwaToken} from "../../contracts/token/RwaToken.sol";
import {RwaTokenTester} from "../../contracts/testers/RwaTokenTester.sol";
import {RefundReplayAttacker} from "../../contracts/testers/RefundReplayAttacker.sol";
import {MockSanctionsList} from "../../contracts/mocks/MockSanctionsList.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract RwaTokenTest is PlatformFixture {
    /// @dev The literal published in the EIP, not `type(IERC7943).interfaceId`: that is what
    ///      makes it a conformance test rather than a tautology.
    bytes4 internal constant EIP_PUBLISHED_INTERFACE_ID = 0x3edbb4c4;

    address internal minter = makeAddr("minter");
    address internal burner = makeAddr("burner");

    function setUp() public {
        _deployAccessLayer();
        _deployCompliance(false);
        _deployToken(false);

        _grantOperational(Roles.MINTER_ROLE, minter);
        _grantOperational(Roles.BURNER_ROLE, burner);
        _grantOperational(Roles.PAUSER_ROLE, pauser);
        _grantOperational(Roles.UNPAUSER_ROLE, unpauser);
        _grantCriticalViaTimelock(Roles.ENFORCER_ROLE, enforcer);
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    function test_TokenShape() public view {
        assertEq(token.name(), "Whitelabel Bond Token");
        assertEq(token.symbol(), "wBOND");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
    }

    function test_RevertWhen_ImplementationIsInitialisedDirectly() public {
        RwaTokenTester impl = new RwaTokenTester();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize("x", "X", address(registry), address(compliance), false);
    }

    function test_RevertWhen_InitialisedWithZeroCompliance() public {
        RwaTokenTester impl = new RwaTokenTester();
        vm.expectRevert(RwaToken.ZeroComplianceRegistry.selector);
        _proxy(
            address(impl),
            abi.encodeCall(RwaTokenTester.initialize, ("x", "X", address(registry), address(0), false))
        );
    }

    function test_TransfersMoveBalances() public {
        _mint(alice, 100e18);

        vm.prank(alice);
        token.transfer(bob, 40e18);

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
    }

    function test_PermitGrantsAllowanceWithoutATransaction() public {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        _mint(owner, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                50e18,
                token.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, bob, 50e18, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), 50e18);
        vm.prank(bob);
        token.transferFrom(owner, bob, 50e18);
        assertEq(token.balanceOf(bob), 50e18);
    }

    /// @dev If a signature drifts, integrators discovering this token through
    ///      `supportsInterface` silently stop finding it.
    function test_InterfaceIdMatchesThePublishedValue() public view {
        assertEq(type(IERC7943).interfaceId, EIP_PUBLISHED_INTERFACE_ID);
        assertTrue(token.supportsInterface(EIP_PUBLISHED_INTERFACE_ID));
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertFalse(token.supportsInterface(0xdeadbeef));
    }

    function test_SetFrozenTokensBlocksExactlyTheFrozenPortion() public {
        _mint(alice, 100e18);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC7943.Frozen(alice, 30e18);
        vm.prank(enforcer);
        token.setFrozenTokens(alice, 30e18);

        assertEq(token.getFrozenTokens(alice), 30e18);
        assertTrue(token.canTransfer(alice, bob, 70e18));
        assertFalse(token.canTransfer(alice, bob, 71e18));

        vm.prank(alice);
        token.transfer(bob, 70e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943.ERC7943InsufficientUnfrozenBalance.selector, alice, 1, 0)
        );
        token.transfer(bob, 1);
    }

    /// @dev The EIP requires freezing more than the held balance to be permitted.
    function test_FreezingMoreThanTheBalanceIsAllowed() public {
        _mint(alice, 10e18);

        vm.prank(enforcer);
        token.setFrozenTokens(alice, 1_000e18);

        assertEq(token.getFrozenTokens(alice), 1_000e18);
        assertFalse(token.canTransfer(alice, bob, 1));
    }

    function test_RevertWhen_NonEnforcerFreezesOrForces() public {
        _mint(alice, 10e18);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.ENFORCER_ROLE, admin)
        );
        token.setFrozenTokens(alice, 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.ENFORCER_ROLE, admin)
        );
        token.forcedTransfer(alice, bob, 1);
    }

    /// @dev The EIP requires unfreezing first and emitting `Frozen` BEFORE the transfer event.
    ///      The ordering is normative.
    function test_ForcedTransferReleasesFrozenTokensFirst() public {
        _mint(alice, 100e18);
        vm.prank(enforcer);
        token.setFrozenTokens(alice, 100e18);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC7943.Frozen(alice, 40e18); // 100 held - 60 seized
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 60e18);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC7943.ForcedTransfer(alice, bob, 60e18);

        vm.prank(enforcer);
        token.forcedTransfer(alice, bob, 60e18);

        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.getFrozenTokens(alice), 40e18);
    }

    function test_ForcedTransferLeavesFrozenAloneWhenUnfrozenSuffices() public {
        _mint(alice, 100e18);
        vm.prank(enforcer);
        token.setFrozenTokens(alice, 30e18);

        vm.prank(enforcer);
        token.forcedTransfer(alice, bob, 50e18);

        assertEq(token.getFrozenTokens(alice), 30e18);
    }

    /// @dev Seizure from a blacklisted or sanctioned account is the purpose of this path, so it
    ///      must bypass the gates that would otherwise stop it.
    function test_ForcedTransferWorksAgainstBlacklistedAndSanctionedAccounts() public {
        _mint(alice, 100e18);
        _blacklist(alice);
        sanctions.setSanctioned(alice, true);

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        vm.prank(enforcer);
        token.forcedTransfer(alice, bob, 100e18);

        assertEq(token.balanceOf(bob), 100e18);
    }

    function test_BlacklistBlocksTransfersInBothDirections() public {
        _mint(alice, 100e18);
        _mint(bob, 100e18);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        token.transfer(bob, 1e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        token.transfer(alice, 1e18);

        assertFalse(token.canSend(alice));
        assertFalse(token.canReceive(alice));
    }

    function test_SanctionsBlockTransfers() public {
        _mint(alice, 100e18);
        sanctions.setSanctioned(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.SanctionedAccount.selector, alice));
        token.transfer(bob, 1e18);
    }

    /// @dev ERC-7943 forbids these predicates from reverting. A downed sanctions oracle is where
    ///      a naive implementation would.
    function test_ViewPredicatesNeverRevertEvenWithABrokenOracle() public {
        sanctions.setMode(MockSanctionsList.Mode.Revert);
        assertFalse(token.canSend(alice));
        assertFalse(token.canReceive(alice));
        assertFalse(token.canTransfer(alice, bob, 1));

        sanctions.setMode(MockSanctionsList.Mode.GasBomb);
        assertFalse(token.canSend(alice));
        assertFalse(token.canReceive(alice));
        assertFalse(token.canTransfer(alice, bob, 1));
    }

    function test_MintRefusesBlockedRecipients() public {
        _blacklist(alice);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        token.mint(alice, 1e18);
    }

    function test_PauseStopsOrdinaryTransfers() public {
        _mint(alice, 100e18);

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        vm.prank(alice);
        vm.expectRevert(RwaToken.TransfersPaused.selector);
        token.transfer(bob, 1e18);

        assertFalse(token.canSend(alice));
        assertFalse(token.canTransfer(alice, bob, 1e18));

        vm.prank(unpauser);
        token.unpauseOperation(Roles.OP_TRANSFER);

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    /// @dev Any divergence between "canTransfer says yes" and "the transfer succeeds" is an
    ///      integration hazard for anyone building on the ERC-7943 surface.
    function testFuzz_PredicateAgreesWithActualTransfers(
        bool blacklisted,
        bool sanctioned,
        bool paused,
        uint96 frozenAmount
    ) public {
        _mint(alice, 100e18);

        if (blacklisted) _blacklist(alice);
        if (sanctioned) sanctions.setSanctioned(alice, true);
        if (paused) {
            vm.prank(pauser);
            token.pauseOperation(Roles.OP_TRANSFER);
        }
        if (frozenAmount != 0) {
            vm.prank(enforcer);
            token.setFrozenTokens(alice, frozenAmount);
        }

        bool predicted = token.canTransfer(alice, bob, 50e18);

        vm.prank(alice);
        try token.transfer(bob, 50e18) {
            assertTrue(predicted, "transfer succeeded while canTransfer said no");
        } catch {
            assertFalse(predicted, "transfer reverted while canTransfer said yes");
        }
    }

    function test_OnlyMinterMintsAndOnlyBurnerBurns() public {
        _mint(alice, 100e18);
        assertEq(token.totalSupply(), 100e18);

        vm.prank(burner);
        token.burn(alice, 40e18);
        assertEq(token.totalSupply(), 60e18);

        vm.prank(burner);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.MINTER_ROLE, burner)
        );
        token.mint(alice, 1e18);

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.BURNER_ROLE, minter)
        );
        token.burn(alice, 1e18);
    }

    function test_BurnRespectsFrozenBalances() public {
        _mint(alice, 100e18);
        vm.prank(enforcer);
        token.setFrozenTokens(alice, 90e18);

        vm.prank(burner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7943.ERC7943InsufficientUnfrozenBalance.selector,
                alice,
                20e18,
                10e18
            )
        );
        token.burn(alice, 20e18);
    }

    function _deployVaultStandIn() internal returns (RefundReplayAttacker vaultStandIn) {
        vaultStandIn = new RefundReplayAttacker(token);
        _grantCriticalViaTimelock(Roles.REFUND_VAULT_ROLE, address(vaultStandIn));
        _mint(address(vaultStandIn), 100e18);
    }

    /// @dev Why the carve-out exists: a user cancelling a redemption while transfers are paused
    ///      must still get their escrow back.
    function test_RefundSucceedsWhileTransfersArePaused() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        vm.expectEmit(true, true, false, true, address(token));
        emit RwaToken.RefundFromVault(address(vaultStandIn), alice, 25e18);
        vaultStandIn.refund(alice, 25e18);

        assertEq(token.balanceOf(alice), 25e18);
    }

    /// @dev Blacklisting must not become confiscation by accident.
    function test_RefundSucceedsToABlacklistedUser() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();
        _blacklist(alice);

        vaultStandIn.refund(alice, 25e18);
        assertEq(token.balanceOf(alice), 25e18);
    }

    /// @dev Sanctions are the one control the carve-out does not relax.
    function test_RevertWhen_RefundTargetIsSanctioned() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();
        sanctions.setSanctioned(alice, true);

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.SanctionedAccount.selector, alice));
        vaultStandIn.refund(alice, 25e18);
    }

    /// @dev An unreachable oracle also stops the refund. Fail-closed beats guessing.
    function test_RevertWhen_RefundRunsWithABrokenSanctionsOracle() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();
        sanctions.setMode(MockSanctionsList.Mode.Revert);

        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceRegistry.SanctionsOracleUnavailable.selector,
                address(vaultStandIn)
            )
        );
        vaultStandIn.refund(alice, 25e18);
    }

    function test_RevertWhen_CallerLacksTheRefundRole() public {
        _mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.REFUND_VAULT_ROLE, alice)
        );
        token.refundFromVault(bob, 1e18);
    }

    /// @dev THE load-bearing regression test for the one-shot ticket. EIP-1153 storage is
    ///      transaction-scoped, not frame-scoped, so an authorisation left behind would silently
    ///      extend to every later transfer in the same transaction.
    function test_RevertWhen_RefundIsFollowedByAnOrdinaryTransferInTheSameTx() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        vm.expectRevert(RwaToken.TransfersPaused.selector);
        vaultStandIn.refundThenTransfer(alice, 10e18, 10e18);
    }

    /// @dev Same property, exercised through the blacklist rather than the pause.
    function test_RevertWhen_RefundIsFollowedByATransferToABlacklistedAccount() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();
        _blacklist(alice);

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        vaultStandIn.refundThenTransfer(alice, 10e18, 10e18);
    }

    /// @dev Note what this does NOT test. Amount-binding is structural — the ticket lives in a
    ///      slot derived from `(from, to, amount)`, so a mismatched transfer reads a different,
    ///      empty slot — and no reachable path has a live ticket meeting a transfer of another
    ///      amount, because `refundFromVault` issues and spends it with no external call in
    ///      between. A test cannot reach the case.
    function test_RevertWhen_ATransferOfAnotherAmountFollowsARefund() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        vm.expectRevert(RwaToken.TransfersPaused.selector);
        vaultStandIn.refundThenTransferDifferentAmount(alice, 10e18, 5e18);
    }

    /// @dev Single-USE, not once-per-transaction: two separately authorised refunds in one
    ///      transaction are both legitimate.
    function test_TwoRefundsInOneTransactionBothSucceed() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        vaultStandIn.refundTwice(alice, 10e18, 15e18);
        assertEq(token.balanceOf(alice), 25e18);
    }

    /// @dev Documented divergence: with transfers paused, `canSend` reports false for the vault,
    ///      yet the refund path still works.
    function test_CanSendReportsFalseWhileRefundsStillSucceed() public {
        RefundReplayAttacker vaultStandIn = _deployVaultStandIn();

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        assertFalse(token.canSend(address(vaultStandIn)));
        vaultStandIn.refund(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
    }

    /// @dev `forcedTransfer` skips MORE than the refund path does — sanctions and the frozen
    ///      check included — so a leaked enforcement ticket is the worse of the two.
    function test_RevertWhen_ForcedTransferIsFollowedByAnOrdinaryTransferInTheSameTx() public {
        _mint(alice, 100e18);

        RefundReplayAttacker enforcerContract = new RefundReplayAttacker(token);
        _grantCriticalViaTimelock(Roles.ENFORCER_ROLE, address(enforcerContract));

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        // The forced leg lands; the ordinary leg must meet the full gate set.
        vm.expectRevert(RwaToken.TransfersPaused.selector);
        enforcerContract.forceThenTransfer(alice, bob, 10e18, 10e18);
    }

    /// @dev Single-USE, the same property the refund path has.
    function test_TwoForcedTransfersInOneTransactionBothSucceed() public {
        _mint(alice, 100e18);

        RefundReplayAttacker enforcerContract = new RefundReplayAttacker(token);
        _grantCriticalViaTimelock(Roles.ENFORCER_ROLE, address(enforcerContract));

        vm.prank(pauser);
        token.pauseOperation(Roles.OP_TRANSFER);

        enforcerContract.forceTwice(alice, bob, 10e18, 15e18);
        assertEq(token.balanceOf(bob), 25e18);
    }

    function test_TimelockSwapsTheComplianceModule() public {
        ComplianceRegistry impl = new ComplianceRegistry();
        ComplianceRegistry replacement = ComplianceRegistry(
            _proxy(
                address(impl),
                abi.encodeCall(
                    ComplianceRegistry.initialize,
                    (address(registry), address(0), false)
                )
            )
        );

        _mint(alice, 10e18);
        _blacklist(alice);

        _executeViaTimelock(
            address(token),
            abi.encodeCall(token.setComplianceRegistry, (address(replacement)))
        );

        assertEq(address(token.complianceRegistry()), address(replacement));
        // The old blacklist entry no longer applies: the rulebook was replaced wholesale.
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_RevertWhen_ComplianceModuleIsSwappedOutsideTheTimelock() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                admin
            )
        );
        token.setComplianceRegistry(address(1));
    }

    function test_RevertWhen_ComplianceModuleIsSetToZero() public {
        vm.prank(address(timelock));
        vm.expectRevert(RwaToken.ZeroComplianceRegistry.selector);
        token.setComplianceRegistry(address(0));
    }

    function test_RoleGettersDefaultToTheCanonicalConstants() public view {
        assertEq(token.minterRole(), Roles.MINTER_ROLE);
        assertEq(token.burnerRole(), Roles.BURNER_ROLE);
        assertEq(token.refundVaultRole(), Roles.REFUND_VAULT_ROLE);
        assertEq(token.enforcerRole(), Roles.ENFORCER_ROLE);
    }

    function test_OnlyTransferIsPausableOnTheToken() public view {
        bytes32[] memory ops = token.supportedOperations();
        assertEq(ops.length, 1);
        assertEq(ops[0], Roles.OP_TRANSFER);
    }

    function test_ProductionDeploysWithTransfersPaused() public {
        _deployToken(true);
        assertTrue(token.isOperationPaused(Roles.OP_TRANSFER));
    }

    function test_InsufficientBalanceStillUsesTheStandardError() public {
        _mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18)
        );
        token.transfer(bob, 2e18);
    }

    function test_RevertWhen_NonUpgraderUpgradesToken() public {
        RwaTokenTester nextImpl = new RwaTokenTester();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UPGRADER_ROLE, admin)
        );
        token.upgradeToAndCall(address(nextImpl), "");
    }

    function test_TimelockUpgradesTokenAndStatePersists() public {
        _mint(alice, 42e18);
        vm.prank(enforcer);
        token.setFrozenTokens(alice, 7e18);

        RwaTokenTester nextImpl = new RwaTokenTester();
        _executeViaTimelock(
            address(token),
            abi.encodeCall(token.upgradeToAndCall, (address(nextImpl), ""))
        );

        assertEq(token.balanceOf(alice), 42e18);
        assertEq(token.getFrozenTokens(alice), 7e18);
        assertEq(token.name(), "Whitelabel Bond Token");
    }
}
