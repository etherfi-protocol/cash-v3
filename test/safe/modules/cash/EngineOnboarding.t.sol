// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, ICashModule } from "../../../../src/interfaces/ICashModule.sol";
import { SpendingLimit } from "../../../../src/libraries/SpendingLimitLib.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

/**
 * @title EngineOnboardingTest
 * @notice The backend picks a new safe's engine at deploy time through the useLendGateway flag in the cash
 *         setup data. A safe onboarded with the flag set lands on the Aave gateway; without it, on the legacy
 *         DebtManager. This suite runs on the default profile with the mock gateway, and starts from an unset
 *         gateway so it can drive both engines from scratch.
 * @dev The admin-migrate path that moves a legacy safe onto the gateway is covered by the real-gateway
 *      DebtManagerMigration test.
 */
contract EngineOnboardingTest is CashModuleTestSetup {
    /// @dev Start with no gateway configured, so the tests wire it themselves.
    function _wireDefaultGateway() internal override { }

    /// @dev The base default safe deploys before this suite wires a gateway, so it onboards legacy.
    function _newSafeUsesLend() internal pure override returns (bool) {
        return false;
    }

    /// The base default safe onboarded without the flag, so it runs on the legacy engine.
    function test_defaultSafe_onboardsLegacy() public view {
        assertFalse(cashModule.usesLendGateway(address(safe)), "default safe is legacy");
    }

    /// A safe onboarded with the flag set, once a gateway is configured, lands on the gateway.
    function test_deploy_withFlag_onboardsGateway() public {
        _wireGateway();
        assertTrue(cashModule.usesLendGateway(_deploySafe("onboard-gateway", true)), "flagged safe is on the gateway");
    }

    /// A safe onboarded without the flag lands on the legacy engine, even with a gateway configured.
    function test_deploy_withoutFlag_onboardsLegacy() public {
        _wireGateway();
        assertFalse(cashModule.usesLendGateway(_deploySafe("onboard-legacy", false)), "unflagged safe is legacy");
    }

    /// The three-field setup payload used before Lend still deploys a correctly configured legacy Safe.
    function test_deploy_withLegacySetup_onboardsLegacy() public {
        _wireGateway();
        address legacySafe = _deployLegacySafe("onboard-legacy-payload");
        SpendingLimit memory limit = cashLens.applicableSpendingLimit(legacySafe);

        assertFalse(cashModule.usesLendGateway(legacySafe), "legacy payload safe is legacy");
        assertEq(limit.dailyLimit, dailyLimitInUsd, "daily limit initialized");
        assertEq(limit.monthlyLimit, monthlyLimitInUsd, "monthly limit initialized");
        assertEq(limit.timezoneOffset, timezoneOffset, "timezone initialized");
    }

    /// Setup rejects data that is neither the legacy three-field payload nor the new four-field payload.
    function test_setup_rejectsUnexpectedPayloadLength() public {
        vm.prank(address(safe));
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset, false, uint256(0)));
    }

    /// Onboarding with the flag set but no gateway configured reverts, so a safe is never flagged for an engine
    /// that cannot run. Asserted at the setupModule level, since the factory wraps a deploy-time revert.
    function test_setup_withFlag_revertsWhenGatewayUnset() public {
        vm.prank(address(safe));
        vm.expectRevert(ICashModule.LendGatewayNotSet.selector);
        cashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset, true));
    }

    /// Re-running setup with the flag set on a safe that carries open DebtManager debt keeps it on the legacy
    /// engine, so its legacy debt is never stranded behind gateway routing.
    function test_reSetup_withFlag_keepsLegacyDebtSafeLegacy() public {
        _wireGateway();

        deal(address(weETH), address(safe), 10 ether);
        deal(address(usdc), address(debtManager), 1_000_000e6);
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), 10e6);

        vm.prank(address(safe));
        cashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset, true));
        assertFalse(cashModule.usesLendGateway(address(safe)), "safe with legacy debt stays legacy");
    }

    /// Re-running setup without the flag never un-flips a safe already on the gateway (the per-safe flag is
    /// one-way).
    function test_reSetup_withoutFlag_doesNotUnflipGatewaySafe() public {
        _wireGateway();
        address gatewaySafe = _deploySafe("onboard-then-resetup", true);
        assertTrue(cashModule.usesLendGateway(gatewaySafe), "onboarded onto the gateway");

        vm.prank(gatewaySafe);
        cashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset, false));
        assertTrue(cashModule.usesLendGateway(gatewaySafe), "still on the gateway after a flagless re-setup");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Wires the mock gateway (from base setUp) as the CashModule's lend engine, as owner.
    function _wireGateway() internal {
        vm.prank(owner);
        cashModule.setLendGateway(address(gateway));
    }

    /// @dev Deploys a fresh Safe with the pre-Lend three-field CashModule setup payload.
    function _deployLegacySafe(bytes32 salt) internal returns (address) {
        address[] memory owners = new address[](1);
        owners[0] = owner1;

        address[] memory modules = new address[](1);
        modules[0] = address(cashModule);

        bytes[] memory setupData = new bytes[](1);
        setupData[0] = abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);

        vm.prank(owner);
        safeFactory.deployEtherFiSafe(salt, owners, modules, setupData, 1);
        return safeFactory.getDeterministicAddress(salt);
    }

    /// @dev Deploys a fresh single-owner safe with the CashModule set up, onboarding it onto the gateway when
    ///      useLend is set, and returns its address.
    function _deploySafe(bytes32 salt, bool useLend) internal returns (address) {
        address[] memory owners = new address[](1);
        owners[0] = owner1;

        address[] memory modules = new address[](1);
        modules[0] = address(cashModule);

        bytes[] memory setupData = new bytes[](1);
        setupData[0] = abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset, useLend);

        vm.prank(owner);
        safeFactory.deployEtherFiSafe(salt, owners, modules, setupData, 1);
        return safeFactory.getDeterministicAddress(salt);
    }
}
