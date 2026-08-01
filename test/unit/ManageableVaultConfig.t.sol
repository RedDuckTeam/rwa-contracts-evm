// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {ComplianceRegistry} from "../../contracts/compliance/ComplianceRegistry.sol";
import {OperationPausable} from "../../contracts/pause/OperationPausable.sol";
import {DepositVault} from "../../contracts/vaults/DepositVault.sol";
import {ManageableVault} from "../../contracts/vaults/ManageableVault.sol";
import {RedemptionVault} from "../../contracts/vaults/RedemptionVault.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

/// @dev Split from the behavioural suites: these check what a MISCONFIGURED or freshly-deployed
///      vault looks like — the states a fork lands in before any user interacts with it.
contract ManageableVaultConfigTest is PlatformFixture {
    function setUp() public {
        _deployPlatform();
    }

    /// @dev Independently, so a fork cannot deploy a vault with one leg dangling and discover it
    ///      only when a user's money is at stake.
    function test_RevertWhen_AnyWiringAddressIsZero() public {
        DepositVault impl = new DepositVault();

        ManageableVault.VaultInitParams memory params = _vaultParams();
        params.rwaToken = address(0);
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        _proxy(address(impl), abi.encodeCall(DepositVault.initialize, (params, MAX_SUPPLY_CAP_WAD)));

        params = _vaultParams();
        params.dataFeed = address(0);
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        _proxy(address(impl), abi.encodeCall(DepositVault.initialize, (params, MAX_SUPPLY_CAP_WAD)));

        params = _vaultParams();
        params.complianceRegistry = address(0);
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        _proxy(address(impl), abi.encodeCall(DepositVault.initialize, (params, MAX_SUPPLY_CAP_WAD)));

        params = _vaultParams();
        params.feeReceiver = address(0);
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        _proxy(address(impl), abi.encodeCall(DepositVault.initialize, (params, MAX_SUPPLY_CAP_WAD)));

        params = _vaultParams();
        params.blockedFundsReceiver = address(0);
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        _proxy(address(impl), abi.encodeCall(DepositVault.initialize, (params, MAX_SUPPLY_CAP_WAD)));
    }

    /// @dev The production start state: nothing moves until verification passes and the unpause
    ///      is executed as the final handover step.
    function test_ProductionDeploysWithEveryOperationPaused() public {
        DepositVault depositImpl = new DepositVault();
        RedemptionVault redemptionImpl = new RedemptionVault();

        ManageableVault.VaultInitParams memory params = _vaultParams();
        params.startPaused = true;

        DepositVault pausedDeposit = DepositVault(
            _proxy(
                address(depositImpl),
                abi.encodeCall(DepositVault.initialize, (params, MAX_SUPPLY_CAP_WAD))
            )
        );
        RedemptionVault pausedRedemption = RedemptionVault(
            _proxy(
                address(redemptionImpl),
                abi.encodeCall(RedemptionVault.initialize, (params, treasury))
            )
        );

        assertTrue(pausedDeposit.isOperationPaused(Roles.OP_DEPOSIT_INSTANT));
        assertTrue(pausedDeposit.isOperationPaused(Roles.OP_DEPOSIT_REQUEST));
        assertTrue(pausedRedemption.isOperationPaused(Roles.OP_REDEEM_INSTANT));
        assertTrue(pausedRedemption.isOperationPaused(Roles.OP_REDEEM_REQUEST));
    }

    function test_RevertWhen_ImplementationsAreInitialisedDirectly() public {
        DepositVault depositImpl = new DepositVault();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        depositImpl.initialize(_vaultParams(), MAX_SUPPLY_CAP_WAD);

        RedemptionVault redemptionImpl = new RedemptionVault();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        redemptionImpl.initialize(_vaultParams(), treasury);
    }

    function test_RevertWhen_RedemptionVaultGetsAZeroProvider() public {
        RedemptionVault impl = new RedemptionVault();
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        _proxy(address(impl), abi.encodeCall(RedemptionVault.initialize, (_vaultParams(), address(0))));
    }

    /// @dev Every parameter the deployment verifier checks must be externally readable.
    function test_ConfigurationIsFullyReadable() public view {
        assertEq(address(depositVault.rwaToken()), address(token));
        assertEq(address(depositVault.dataFeed()), address(dataFeed));
        assertEq(address(depositVault.complianceRegistry()), address(compliance));

        assertEq(depositVault.tokensReceiver(), treasury);
        assertEq(depositVault.feeReceiver(), feeCollector);
        assertEq(depositVault.blockedFundsReceiver(), blockedFunds);

        assertEq(depositVault.instantFeeBps(), INSTANT_FEE_BPS);
        assertEq(depositVault.instantDailyLimitWad(), DAILY_LIMIT_WAD);
        assertEq(depositVault.minAmountWad(), MIN_AMOUNT_WAD);
        assertEq(depositVault.minFirstAmountWad(), MIN_FIRST_AMOUNT_WAD);
        assertEq(depositVault.variationToleranceBps(), VARIATION_TOLERANCE_BPS);
        assertEq(depositVault.maxSupplyCapWad(), MAX_SUPPLY_CAP_WAD);

        assertEq(depositVault.nextRequestId(), 1);
        assertEq(depositVault.spentTodayWad(), 0);

        assertFalse(depositVault.isFeeWaived(alice));
        assertFalse(depositVault.isMinAmountWaived(alice));

        assertEq(redemptionVault.tokensProvider(), treasury);
    }

    function test_WaiversAreReadableAfterBeingSet() public {
        vm.startPrank(vaultAdmin);
        depositVault.setFeeWaiver(alice, true);
        depositVault.setMinAmountWaiver(alice, true);
        vm.stopPrank();

        assertTrue(depositVault.isFeeWaived(alice));
        assertTrue(depositVault.isMinAmountWaived(alice));
    }

    /// @dev Split across three contracts with no overlap, and together covering exactly the set
    ///      declared in {Roles}.
    function test_PausableOperationsPartitionCleanlyAcrossTheDeployment() public {
        bytes32[] memory depositOps = depositVault.supportedOperations();
        assertEq(depositOps.length, 2);
        assertEq(depositOps[0], Roles.OP_DEPOSIT_INSTANT);
        assertEq(depositOps[1], Roles.OP_DEPOSIT_REQUEST);

        bytes32[] memory redemptionOps = redemptionVault.supportedOperations();
        assertEq(redemptionOps.length, 2);
        assertEq(redemptionOps[0], Roles.OP_REDEEM_INSTANT);
        assertEq(redemptionOps[1], Roles.OP_REDEEM_REQUEST);

        assertEq(token.supportedOperations().length, 1);
        assertEq(token.supportedOperations()[0], Roles.OP_TRANSFER);

        assertEq(aggregator.supportedOperations().length, 1);
        assertEq(aggregator.supportedOperations()[0], Roles.OP_ORACLE_UPDATE);

        // Pranked as a real PAUSER so the revert is the UnsupportedOperation guard rather than
        // the role check: an unpranked call reverts first on `onlyRegistryRole`, and the test
        // would pass with `_isSupportedOperation` deleted.
        assertFalse(depositVault.isOperationPaused(Roles.OP_REDEEM_INSTANT));

        _grantOperational(Roles.PAUSER_ROLE, pauser);
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(OperationPausable.UnsupportedOperation.selector, Roles.OP_TRANSFER)
        );
        depositVault.pauseOperation(Roles.OP_TRANSFER);
    }

    /// @dev On UPDATE as well as registration: checking only on the way in would let an admin
    ///      register at 0 bps and then raise past the ceiling.
    function test_RevertWhen_UpdatingATokenPastTheFeeCap() public {
        uint256 maxTokenFee = depositVault.MAX_TOKEN_FEE_BPS();

        vm.prank(vaultAdmin);
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.updatePaymentToken(address(usdc), true, maxTokenFee + 1, type(uint256).max);
    }

    function test_RevertWhen_VariationToleranceWouldExceedItsCap() public {
        uint256 maxTolerance = depositVault.MAX_VARIATION_TOLERANCE_BPS();

        vm.prank(address(timelock));
        vm.expectRevert(ManageableVault.ConfigOutOfRange.selector);
        depositVault.setVariationToleranceBps(maxTolerance + 1);
    }

    /// @dev The registry keeps two views of a token: the config mapping and an append-only list.
    ///      Registration used to be inferred from `decimals != 0`, which made "registered" and
    ///      "declares zero decimals" the same state — such a token was pushed onto the list
    ///      while reading back as unregistered, leaving it permanently unusable, un-updatable
    ///      and un-removable.
    function test_RevertWhen_PaymentTokenDeclaresZeroDecimals() public {
        MockERC20 zeroDecimals = new MockERC20("Zero", "ZRO", 0);

        vm.prank(vaultAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManageableVault.UnsupportedTokenDecimals.selector,
                address(zeroDecimals)
            )
        );
        depositVault.addPaymentToken(address(zeroDecimals), 0, type(uint256).max);

        // And nothing was recorded on either view.
        assertEq(depositVault.paymentTokens().length, 2);
        assertFalse(depositVault.paymentTokenConfig(address(zeroDecimals)).registered);
    }

    /// @dev A token consuming the entire transfer delivers nothing; without this the vault would
    ///      proceed with a zero credit and mint zero tokens for real money.
    function test_RevertWhen_ATokenDeliversNothing() public {
        usdt.setTransferFeeBps(10_000); // withholds 100%
        usdt.mint(alice, 100_000e6);

        vm.startPrank(alice);
        usdt.approve(address(depositVault), type(uint256).max);
        vm.expectRevert(ManageableVault.ZeroAmount.selector);
        depositVault.depositInstant(address(usdt), 10_000e6, 0);
        vm.stopPrank();
    }

    /// @dev The extension seam for a fork with different rules: swap the module rather than edit
    ///      the vault. Timelocked, because it replaces the rulebook in one transaction.
    function test_TimelockSwapsTheVaultComplianceModule() public {
        ComplianceRegistry impl = new ComplianceRegistry();
        ComplianceRegistry replacement = ComplianceRegistry(
            _proxy(
                address(impl),
                abi.encodeCall(ComplianceRegistry.initialize, (address(registry), address(0), true))
            )
        );

        _executeViaTimelock(
            address(depositVault),
            abi.encodeCall(depositVault.setComplianceRegistry, (address(replacement)))
        );

        assertEq(address(depositVault.complianceRegistry()), address(replacement));

        // The new module enforces its own greenlist, and the old one's state is irrelevant.
        _fundWithUsdc(alice, 100_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.NotGreenlisted.selector, alice));
        depositVault.depositInstant(address(usdc), 10_000e6, 0);
    }
}
