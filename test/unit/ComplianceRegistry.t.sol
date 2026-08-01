// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {Roles} from "../../contracts/access/Roles.sol";
import {WithAccessRegistry} from "../../contracts/access/WithAccessRegistry.sol";
import {ComplianceRegistry} from "../../contracts/compliance/ComplianceRegistry.sol";
import {MockSanctionsList} from "../../contracts/mocks/MockSanctionsList.sol";
import {PlatformFixture} from "../helpers/PlatformFixture.sol";

contract ComplianceRegistryTest is PlatformFixture {
    function setUp() public {
        _deployAccessLayer();
        _deployCompliance(false);
    }

    function test_InitialiseWiresRegistryAndOracle() public view {
        assertEq(address(compliance.accessRegistry()), address(registry));
        assertEq(compliance.sanctionsOracle(), address(sanctions));
        assertFalse(compliance.greenlistEnabled());
    }

    function test_ProductionStartsWithTheGreenlistEnforced() public {
        ComplianceRegistry impl = new ComplianceRegistry();
        ComplianceRegistry fresh = ComplianceRegistry(
            _proxy(
                address(impl),
                abi.encodeCall(
                    ComplianceRegistry.initialize,
                    (address(registry), address(sanctions), true)
                )
            )
        );

        assertTrue(fresh.greenlistEnabled());
        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.NotGreenlisted.selector, alice));
        fresh.checkVaultOp(alice);
    }

    function test_RevertWhen_ImplementationIsInitialisedDirectly() public {
        ComplianceRegistry impl = new ComplianceRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(registry), address(sanctions), true);
    }

    function test_RoleGettersDefaultToTheCanonicalConstants() public view {
        assertEq(compliance.complianceAdminRole(), Roles.COMPLIANCE_ADMIN_ROLE);
        assertEq(compliance.greenlistOperatorRole(), Roles.GREENLIST_OPERATOR_ROLE);
        assertEq(compliance.blacklistOperatorRole(), Roles.BLACKLIST_OPERATOR_ROLE);
    }

    function test_BlacklistBlocksBothSidesOfATransfer() public {
        _blacklist(alice);

        assertTrue(compliance.isBlacklisted(alice));
        assertFalse(compliance.isPartyAllowed(alice));
        assertFalse(compliance.isVaultOpAllowed(alice));

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        compliance.checkTransfer(alice, bob);

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        compliance.checkTransfer(bob, alice);

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        compliance.checkVaultOp(alice);
    }

    function test_BlacklistCanBeLifted() public {
        _blacklist(alice);

        vm.prank(blacklistOperator);
        compliance.setBlacklisted(alice, false);

        assertFalse(compliance.isBlacklisted(alice));
        compliance.checkTransfer(alice, bob);
    }

    function test_EmitsBlacklistEvent() public {
        vm.expectEmit(true, false, false, true, address(compliance));
        emit ComplianceRegistry.BlacklistUpdated(alice, true);
        vm.prank(blacklistOperator);
        compliance.setBlacklisted(alice, true);
    }

    /// @dev Why prohibitions are kept out of AccessControl: a role-modelled blacklist would
    ///      hand the blacklisted account `renounceRole`.
    function test_RevertWhen_AccountClearsItsOwnBlacklistEntry() public {
        // The operator key itself gets blacklisted.
        _blacklist(blacklistOperator);

        vm.prank(blacklistOperator);
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceRegistry.SelfUnblacklistForbidden.selector, blacklistOperator)
        );
        compliance.setBlacklisted(blacklistOperator, false);

        assertTrue(compliance.isBlacklisted(blacklistOperator));
    }

    /// @dev By a different operator, never by itself.
    function test_AnotherOperatorCanClearABlacklistedOperator() public {
        _blacklist(blacklistOperator);
        _grantOperational(Roles.BLACKLIST_OPERATOR_ROLE, bob);

        vm.prank(bob);
        compliance.setBlacklisted(blacklistOperator, false);

        assertFalse(compliance.isBlacklisted(blacklistOperator));
    }

    function test_RevertWhen_NonOperatorTouchesTheBlacklist() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.BLACKLIST_OPERATOR_ROLE,
                alice
            )
        );
        compliance.setBlacklisted(bob, true);
    }

    function test_RevertWhen_BlacklistStatusWouldNotChange() public {
        vm.prank(blacklistOperator);
        vm.expectRevert(ComplianceRegistry.StatusUnchanged.selector);
        compliance.setBlacklisted(alice, false);
    }

    /// @dev The KYC model: the greenlist gates issuance and redemption only.
    function test_GreenlistGatesVaultOperationsButNotTransfers() public {
        vm.prank(complianceAdmin);
        compliance.setGreenlistEnabled(true);

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.NotGreenlisted.selector, alice));
        compliance.checkVaultOp(alice);
        assertFalse(compliance.isVaultOpAllowed(alice));

        // ...yet a plain transfer between the same two accounts is fine.

        compliance.checkTransfer(alice, bob);
        assertTrue(compliance.isPartyAllowed(alice));

        assertFalse(compliance.isGreenlisted(alice));

        _greenlist(alice);

        assertTrue(compliance.isGreenlisted(alice));
        compliance.checkVaultOp(alice);
        assertTrue(compliance.isVaultOpAllowed(alice));
    }

    function test_DisablingTheGreenlistOpensVaultOperations() public {
        vm.prank(complianceAdmin);
        compliance.setGreenlistEnabled(true);

        vm.prank(complianceAdmin);
        compliance.setGreenlistEnabled(false);

        compliance.checkVaultOp(alice);
        assertTrue(compliance.isVaultOpAllowed(alice));
    }

    function test_BlacklistBeatsGreenlist() public {
        _greenlist(alice);
        _blacklist(alice);

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.BlacklistedAccount.selector, alice));
        compliance.checkVaultOp(alice);
    }

    function test_EmitsGreenlistEvents() public {
        vm.expectEmit(true, false, false, true, address(compliance));
        emit ComplianceRegistry.GreenlistUpdated(alice, true);
        vm.prank(greenlistOperator);
        compliance.setGreenlisted(alice, true);

        vm.expectEmit(false, false, false, true, address(compliance));
        emit ComplianceRegistry.GreenlistEnabledUpdated(true);
        vm.prank(complianceAdmin);
        compliance.setGreenlistEnabled(true);
    }

    function test_RevertWhen_NonOperatorTouchesTheGreenlist() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.GREENLIST_OPERATOR_ROLE,
                alice
            )
        );
        compliance.setGreenlisted(bob, true);

        vm.prank(greenlistOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.COMPLIANCE_ADMIN_ROLE,
                greenlistOperator
            )
        );
        compliance.setGreenlistEnabled(true);
    }

    function test_RevertWhen_GreenlistStatusWouldNotChange() public {
        vm.prank(greenlistOperator);
        vm.expectRevert(ComplianceRegistry.StatusUnchanged.selector);
        compliance.setGreenlisted(alice, false);

        vm.prank(complianceAdmin);
        vm.expectRevert(ComplianceRegistry.StatusUnchanged.selector);
        compliance.setGreenlistEnabled(false);
    }

    function test_SanctionedAccountIsRefusedEverywhere() public {
        sanctions.setSanctioned(alice, true);

        assertFalse(compliance.isPartyAllowed(alice));
        assertFalse(compliance.isVaultOpAllowed(alice));

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.SanctionedAccount.selector, alice));
        compliance.checkTransfer(alice, bob);

        vm.expectRevert(abi.encodeWithSelector(ComplianceRegistry.SanctionedAccount.selector, alice));
        compliance.checkVaultOp(alice);
    }

    /// @dev Both failure behaviours side by side: money paths must stop, the ERC-7943 view
    ///      predicates must keep answering because the EIP forbids them from reverting.
    function test_RevertingOracleStopsMoneyPathsButNotViewPaths() public {
        sanctions.setMode(MockSanctionsList.Mode.Revert);

        assertFalse(compliance.isPartyAllowed(alice));
        assertFalse(compliance.isVaultOpAllowed(alice));

        vm.expectRevert(
            abi.encodeWithSelector(ComplianceRegistry.SanctionsOracleUnavailable.selector, alice)
        );
        compliance.checkTransfer(alice, bob);

        vm.expectRevert(
            abi.encodeWithSelector(ComplianceRegistry.SanctionsOracleUnavailable.selector, alice)
        );
        compliance.checkVaultOp(alice);
    }

    /// @dev The stipend caps a gas-burning oracle, so the caller survives with enough gas to
    ///      fail cleanly instead of dying.
    function test_GasBombOracleIsContainedByTheStipend() public {
        sanctions.setMode(MockSanctionsList.Mode.GasBomb);

        assertFalse(compliance.isPartyAllowed(alice));

        vm.expectRevert(
            abi.encodeWithSelector(ComplianceRegistry.SanctionsOracleUnavailable.selector, alice)
        );
        compliance.checkTransfer(alice, bob);
    }

    /// @dev A staticcall to an address with no code succeeds and returns nothing, which would
    ///      decode as "not sanctioned": a typo in the oracle address would silently disable the
    ///      gate. The return-length check prevents that.
    function test_NonContractOracleCountsAsUnavailable() public {
        _executeViaTimelock(
            address(compliance),
            abi.encodeCall(compliance.setSanctionsOracle, (makeAddr("notAContract")))
        );

        assertFalse(compliance.isPartyAllowed(alice));
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceRegistry.SanctionsOracleUnavailable.selector, alice)
        );
        compliance.checkTransfer(alice, bob);
    }

    /// @dev Zero means "no sanctions oracle wired": the gate is opt-out per deployment.
    function test_ZeroOracleDisablesTheGateEntirely() public {
        _executeViaTimelock(
            address(compliance),
            abi.encodeCall(compliance.setSanctionsOracle, (address(0)))
        );

        assertEq(compliance.sanctionsOracle(), address(0));
        assertTrue(compliance.isPartyAllowed(alice));
        compliance.checkTransfer(alice, bob);
    }

    function test_ReplacingTheOracleRestoresService() public {
        sanctions.setMode(MockSanctionsList.Mode.Revert);

        MockSanctionsList healthy = new MockSanctionsList();
        _executeViaTimelock(
            address(compliance),
            abi.encodeCall(compliance.setSanctionsOracle, (address(healthy)))
        );

        assertTrue(compliance.isPartyAllowed(alice));
        compliance.checkTransfer(alice, bob);
    }

    function test_EmitsOracleUpdateEvent() public {
        MockSanctionsList next = new MockSanctionsList();
        bytes memory payload = abi.encodeCall(compliance.setSanctionsOracle, (address(next)));

        _scheduleViaTimelock(address(compliance), payload);

        vm.expectEmit(true, true, false, false, address(compliance));
        emit ComplianceRegistry.SanctionsOracleUpdated(address(sanctions), address(next));
        _executeScheduled(address(compliance), payload);
    }

    /// @dev The oracle decides who the protocol refuses to serve, so neither the multisig nor a
    ///      compliance operator may swap it directly.
    function test_RevertWhen_OracleIsChangedOutsideTheTimelock() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                admin
            )
        );
        compliance.setSanctionsOracle(address(0));

        vm.prank(complianceAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithAccessRegistry.MissingRole.selector,
                Roles.CRITICAL_CONFIG_ROLE,
                complianceAdmin
            )
        );
        compliance.setSanctionsOracle(address(0));
    }

    function test_RevertWhen_OracleAddressWouldNotChange() public {
        vm.prank(address(timelock));
        vm.expectRevert(ComplianceRegistry.StatusUnchanged.selector);
        compliance.setSanctionsOracle(address(sanctions));
    }

    /// @dev If the predicate and the money-path check ever diverged, a transfer could pass
    ///      `canSend` and then revert — or worse, the reverse.
    function testFuzz_PredicateAgreesWithTheRevertingCheck(
        bool blacklisted,
        bool sanctioned,
        bool greenlisted,
        bool greenlistOn
    ) public {
        if (blacklisted) _blacklist(alice);
        if (sanctioned) sanctions.setSanctioned(alice, true);
        if (greenlisted) _greenlist(alice);
        if (greenlistOn) {
            vm.prank(complianceAdmin);
            compliance.setGreenlistEnabled(true);
        }

        bool partyAllowed = compliance.isPartyAllowed(alice);
        try compliance.checkTransfer(alice, bob) {
            assertTrue(partyAllowed, "checkTransfer passed while the predicate said no");
        } catch {
            assertFalse(partyAllowed, "checkTransfer reverted while the predicate said yes");
        }

        bool vaultAllowed = compliance.isVaultOpAllowed(alice);
        try compliance.checkVaultOp(alice) {
            assertTrue(vaultAllowed, "checkVaultOp passed while the predicate said no");
        } catch {
            assertFalse(vaultAllowed, "checkVaultOp reverted while the predicate said yes");
        }
    }

    function test_RevertWhen_NonUpgraderUpgradesCompliance() public {
        ComplianceRegistry nextImpl = new ComplianceRegistry();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(WithAccessRegistry.MissingRole.selector, Roles.UPGRADER_ROLE, admin)
        );
        compliance.upgradeToAndCall(address(nextImpl), "");
    }

    function test_TimelockUpgradesComplianceAndStatePersists() public {
        _blacklist(alice);

        ComplianceRegistry nextImpl = new ComplianceRegistry();
        _executeViaTimelock(
            address(compliance),
            abi.encodeCall(compliance.upgradeToAndCall, (address(nextImpl), ""))
        );

        assertTrue(compliance.isBlacklisted(alice));
        assertEq(compliance.sanctionsOracle(), address(sanctions));
    }
}
