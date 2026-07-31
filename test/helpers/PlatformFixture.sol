// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {AccessRegistry} from "../../contracts/access/AccessRegistry.sol";
import {Roles} from "../../contracts/access/Roles.sol";
import {ComplianceRegistry} from "../../contracts/compliance/ComplianceRegistry.sol";
import {AdminNavAggregator} from "../../contracts/oracle/AdminNavAggregator.sol";
import {DataFeed} from "../../contracts/oracle/DataFeed.sol";
import {RwaTokenTester} from "../../contracts/testers/RwaTokenTester.sol";
import {DepositVault} from "../../contracts/vaults/DepositVault.sol";
import {ManageableVault} from "../../contracts/vaults/ManageableVault.sol";
import {RedemptionVault} from "../../contracts/vaults/RedemptionVault.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockSanctionsList} from "../../contracts/mocks/MockSanctionsList.sol";
import {MockUSDT} from "../../contracts/mocks/MockUSDT.sol";

/// @dev Mirrors the production deployment order exactly — timelock first, then the registry
///      initialised with its address. Testing against a different wiring than the deploy
///      script produces would make the role tests meaningless.
abstract contract PlatformFixture is Test {
    uint256 internal constant TIMELOCK_MIN_DELAY = 48 hours;

    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant INITIAL_NAV = 1e8; // 1.00
    int256 internal constant NAV_HARD_MIN = 0.5e8;
    int256 internal constant NAV_HARD_MAX = 10e8;
    uint256 internal constant DEVIATION_BPS = 100; // 1%
    uint256 internal constant UPDATE_COOLDOWN = 1 hours;
    uint256 internal constant HEALTHY_DIFF = 72 hours;
    uint256 internal constant PRICE_MIN_WAD = 0.5e18;
    uint256 internal constant PRICE_MAX_WAD = 10e18;

    AccessRegistry internal registry;
    TimelockController internal timelock;
    ComplianceRegistry internal compliance;
    MockSanctionsList internal sanctions;
    AdminNavAggregator internal aggregator;
    DataFeed internal dataFeed;
    RwaTokenTester internal token;
    DepositVault internal depositVault;
    RedemptionVault internal redemptionVault;
    MockERC20 internal usdc;
    MockUSDT internal usdt;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal complianceAdmin = makeAddr("complianceAdmin");
    address internal greenlistOperator = makeAddr("greenlistOperator");
    address internal blacklistOperator = makeAddr("blacklistOperator");
    address internal feedOperator = makeAddr("feedOperator");
    address internal feedAdmin = makeAddr("feedAdmin");
    address internal enforcer = makeAddr("enforcer");
    address internal vaultAdmin = makeAddr("vaultAdmin");
    address internal requestOperator = makeAddr("requestOperator");
    address internal treasury = makeAddr("treasury");
    address internal feeCollector = makeAddr("feeCollector");
    address internal blockedFunds = makeAddr("blockedFunds");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _deployAccessLayer() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open executor: anyone may execute a matured proposal

        timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));

        AccessRegistry impl = new AccessRegistry();
        registry = AccessRegistry(
            address(
                new ERC1967Proxy(
                    address(impl),
                    // The registry's admin-transfer delay and the timelock's minDelay are the
                    // same number by construction here, which is the production wiring.
                    abi.encodeCall(
                        AccessRegistry.initialize,
                        (admin, address(timelock), uint48(TIMELOCK_MIN_DELAY))
                    )
                )
            )
        );
    }

    /// @param greenlistEnabled_ Production starts `true`; most unit tests pass `false` so the
    ///        gate does not obscure whatever else is under test.
    function _deployCompliance(bool greenlistEnabled_) internal {
        sanctions = new MockSanctionsList();

        ComplianceRegistry impl = new ComplianceRegistry();
        compliance = ComplianceRegistry(
            _proxy(
                address(impl),
                abi.encodeCall(
                    ComplianceRegistry.initialize,
                    (address(registry), address(sanctions), greenlistEnabled_)
                )
            )
        );

        _grantOperational(Roles.COMPLIANCE_ADMIN_ROLE, complianceAdmin);
        _grantOperational(Roles.GREENLIST_OPERATOR_ROLE, greenlistOperator);
        _grantOperational(Roles.BLACKLIST_OPERATOR_ROLE, blacklistOperator);
    }

    function _deployOracle(bool startPaused) internal {
        AdminNavAggregator aggImpl = new AdminNavAggregator();
        aggregator = AdminNavAggregator(
            _proxy(
                address(aggImpl),
                abi.encodeCall(
                    AdminNavAggregator.initialize,
                    (
                        address(registry),
                        FEED_DECIMALS,
                        INITIAL_NAV,
                        NAV_HARD_MIN,
                        NAV_HARD_MAX,
                        DEVIATION_BPS,
                        UPDATE_COOLDOWN,
                        startPaused
                    )
                )
            )
        );

        DataFeed feedImpl = new DataFeed();
        dataFeed = DataFeed(
            _proxy(
                address(feedImpl),
                abi.encodeCall(
                    DataFeed.initialize,
                    (address(registry), address(aggregator), HEALTHY_DIFF, PRICE_MIN_WAD, PRICE_MAX_WAD)
                )
            )
        );

        _grantOperational(Roles.FEED_OPERATOR_ROLE, feedOperator);
        _grantOperational(Roles.FEED_ADMIN_ROLE, feedAdmin);
    }

    function _deployToken(bool startPaused) internal {
        RwaTokenTester impl = new RwaTokenTester();
        token = RwaTokenTester(
            _proxy(
                address(impl),
                abi.encodeCall(
                    RwaTokenTester.initialize,
                    (
                        "Whitelabel Bond Token",
                        "wBOND",
                        address(registry),
                        address(compliance),
                        startPaused
                    )
                )
            )
        );
    }

    uint256 internal constant INSTANT_FEE_BPS = 100; // 1%
    uint256 internal constant DAILY_LIMIT_WAD = 1_000_000e18;
    uint256 internal constant MIN_AMOUNT_WAD = 100e18;
    uint256 internal constant MIN_FIRST_AMOUNT_WAD = 1_000e18;
    uint256 internal constant VARIATION_TOLERANCE_BPS = 100; // 1%
    uint256 internal constant MAX_SUPPLY_CAP_WAD = 100_000_000e18;

    function _vaultParams() internal view returns (ManageableVault.VaultInitParams memory) {
        return
            ManageableVault.VaultInitParams({
                registry: address(registry),
                rwaToken: address(token),
                dataFeed: address(dataFeed),
                complianceRegistry: address(compliance),
                tokensReceiver: treasury,
                feeReceiver: feeCollector,
                blockedFundsReceiver: blockedFunds,
                instantFeeBps: INSTANT_FEE_BPS,
                instantDailyLimitWad: DAILY_LIMIT_WAD,
                minAmountWad: MIN_AMOUNT_WAD,
                minFirstAmountWad: MIN_FIRST_AMOUNT_WAD,
                variationToleranceBps: VARIATION_TOLERANCE_BPS,
                startPaused: false
            });
    }

    /// @dev Mirrors production: MINTER/BURNER are operational grants from the multisig, while
    ///      REFUND_VAULT_ROLE is critical and must come through the timelock.
    function _deployVaults() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockUSDT();

        DepositVault depositImpl = new DepositVault();
        depositVault = DepositVault(
            _proxy(
                address(depositImpl),
                abi.encodeCall(DepositVault.initialize, (_vaultParams(), MAX_SUPPLY_CAP_WAD))
            )
        );

        RedemptionVault redemptionImpl = new RedemptionVault();
        redemptionVault = RedemptionVault(
            _proxy(
                address(redemptionImpl),
                abi.encodeCall(RedemptionVault.initialize, (_vaultParams(), treasury))
            )
        );

        _grantOperational(Roles.MINTER_ROLE, address(depositVault));
        _grantOperational(Roles.BURNER_ROLE, address(redemptionVault));
        _grantOperational(Roles.VAULT_ADMIN_ROLE, vaultAdmin);
        _grantOperational(Roles.REQUEST_OPERATOR_ROLE, requestOperator);
        _grantCriticalViaTimelock(Roles.REFUND_VAULT_ROLE, address(redemptionVault));

        vm.startPrank(vaultAdmin);
        depositVault.addPaymentToken(address(usdc), 0, type(uint256).max);
        depositVault.addPaymentToken(address(usdt), 0, type(uint256).max);
        redemptionVault.addPaymentToken(address(usdc), 0, type(uint256).max);
        redemptionVault.addPaymentToken(address(usdt), 0, type(uint256).max);
        vm.stopPrank();

        // The treasury both receives deposits and funds redemptions, so it must approve the
        // redemption vault to pull from it.
        usdc.mint(treasury, 10_000_000e6);
        usdt.mint(treasury, 10_000_000e6);
        vm.startPrank(treasury);
        usdc.approve(address(redemptionVault), type(uint256).max);
        usdt.approve(address(redemptionVault), type(uint256).max);
        vm.stopPrank();
    }

    function _fundWithUsdc(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(depositVault), type(uint256).max);
    }

    /// @dev Ends with a fresh NAV post. Wiring the critical roles costs two timelock delays, so
    ///      by the time the vaults are live the price posted at aggregator initialisation is
    ///      already ~96h old — past the 72h staleness window. A real deployment posts NAV
    ///      before unpausing for the same reason.
    function _deployPlatform() internal {
        _deployAccessLayer();
        _deployCompliance(false);
        _deployOracle(false);
        _deployToken(false);
        _deployVaults();
        _postNav(INITIAL_NAV);
    }

    function _postNav(int256 answer) internal {
        vm.warp(block.timestamp + UPDATE_COOLDOWN);
        vm.prank(feedOperator);
        aggregator.setRoundDataSafe(answer);
    }

    function _greenlist(address account) internal {
        vm.prank(greenlistOperator);
        compliance.setGreenlisted(account, true);
    }

    function _blacklist(address account) internal {
        vm.prank(blacklistOperator);
        compliance.setBlacklisted(account, true);
    }

    function _grantOperational(bytes32 role, address account) internal {
        vm.prank(admin);
        registry.grantRole(role, account);
    }

    /// @dev Scheduled, waited out, then executed — the way it must actually happen. Tests that
    ///      shortcut this with `vm.prank(address(timelock))` would stop proving the delay is
    ///      enforceable at all.
    function _grantCriticalViaTimelock(bytes32 role, address account) internal {
        bytes memory payload = abi.encodeCall(AccessRegistry.grantRole, (role, account));

        vm.prank(admin);
        timelock.schedule(address(registry), 0, payload, bytes32(0), bytes32(0), TIMELOCK_MIN_DELAY);

        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY);

        timelock.execute(address(registry), 0, payload, bytes32(0), bytes32(0));
    }

    function _executeViaTimelock(address target, bytes memory payload) internal {
        _scheduleViaTimelock(target, payload);
        _executeScheduled(target, payload);
    }

    /// @dev Split from execution so a test can arm `vm.expectEmit` immediately before the
    ///      execute call. Scheduling emits `CallScheduled`, which would otherwise be the log
    ///      the expectation matches against.
    function _scheduleViaTimelock(address target, bytes memory payload) internal {
        vm.prank(admin);
        timelock.schedule(target, 0, payload, bytes32(0), bytes32(0), TIMELOCK_MIN_DELAY);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY);
    }

    function _executeScheduled(address target, bytes memory payload) internal {
        timelock.execute(target, 0, payload, bytes32(0), bytes32(0));
    }

    /// @dev OZ 5.6.0 requires the init calldata in the proxy constructor rather than a call
    ///      afterwards, so the proxy is never live in an uninitialised state.
    function _proxy(address implementation, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }
}
