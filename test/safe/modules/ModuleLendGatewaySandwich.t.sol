// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ILendGateway } from "../../../src/interfaces/ILendGateway.sol";
import { MockLendGateway } from "../../../src/mocks/MockLendGateway.sol";
import { ModuleCheckBalance } from "../../../src/modules/ModuleCheckBalance.sol";
import { ModuleLendGatewaySandwich } from "../../../src/modules/ModuleLendGatewaySandwich.sol";

/// @dev Satisfies the ModuleCheckBalance constructor; the harness overrides everything that touches cashModule.
contract MockDataProvider {
    function getCashModule() external pure returns (address) {
        return address(1);
    }
}

/// @notice Exposes the base's internal bookends so they can be called directly in tests
contract SandwichHarness is ModuleLendGatewaySandwich {
    /// @dev A real consumer resolves this from the CashModule; the harness pins the mock directly.
    ILendGateway private immutable mockGateway;

    /// @dev A real consumer computes this from cashModule.isLendActive; the harness sets it directly (defaults on).
    bool public lendActive = true;
    /// @dev A real consumer computes this from cashModule.usesLendGateway; the harness sets it directly (defaults on).
    bool public onGatewayEngine = true;

    constructor(address _gateway, address _dataProvider) ModuleCheckBalance(_dataProvider) {
        mockGateway = ILendGateway(_gateway);
    }

    function gateway() public view override returns (ILendGateway) {
        return mockGateway;
    }

    function setLendActive(bool active) external {
        lendActive = active;
    }

    function _lendActive(address) internal view override returns (bool) {
        return lendActive;
    }

    function setOnGatewayEngine(bool onEngine) external {
        onGatewayEngine = onEngine;
    }

    function _onGatewayEngine(address) internal view override returns (bool) {
        return onGatewayEngine;
    }

    function withdrawShortfall(address safe, address asset, uint256 amount, uint256 looseAvailable) external {
        _withdrawShortfall(safe, asset, amount, looseAvailable);
    }

    function resupplyToGateway(address safe, address asset, uint256 amount) external {
        _resupplyToGateway(safe, asset, amount);
    }

    function ensureGatewayFloor(address safe, uint256 healthFactorBefore) external view {
        _ensureGatewayFloor(safe, healthFactorBefore);
    }

    function gatewayHealthFactor(address safe) external view returns (uint256) {
        return _gatewayHealthFactor(safe);
    }
}

contract ModuleLendGatewaySandwichTest is Test {
    MockLendGateway gateway;
    SandwichHarness harness;

    uint256 constant AMOUNT = 100e6;
    address safe = makeAddr("safe");
    address asset = makeAddr("asset");

    function setUp() public {
        gateway = new MockLendGateway();
        harness = new SandwichHarness(address(gateway), address(new MockDataProvider()));
    }

    // The withdraw bookend routes to the safe and does not guard health; Aave guards the withdraw itself.
    function test_withdraw_routesToSafe() public {
        gateway.setSuppliedOf(safe, asset, AMOUNT);
        harness.withdrawShortfall(safe, asset, AMOUNT, 0);

        (address s, address a, uint256 amount, address to) = gateway.lastWithdraw();
        assertEq(s, safe);
        assertEq(a, asset);
        assertEq(amount, AMOUNT);
        assertEq(to, safe);
    }

    // The resupply bookend supplies the asset back to Aave and marks it as collateral, with no health guard of its own.
    function test_resupply_suppliesAndSetsCollateral() public {
        gateway.setRegistered(asset, true);
        harness.resupplyToGateway(safe, asset, AMOUNT);

        (address s, address a, uint256 amount, address to) = gateway.lastSupply();
        assertEq(s, safe);
        assertEq(a, asset);
        assertEq(amount, AMOUNT);
        assertEq(to, address(0));
        assertTrue(gateway.usingAsCollateral(safe, asset));
    }

    // An output the gateway does not list as a reserve stays loose in the safe: nothing is supplied.
    function test_resupply_noOpWhenAssetNotRegistered() public {
        harness.resupplyToGateway(safe, asset, AMOUNT);

        (address s,, uint256 amount,) = gateway.lastSupply();
        assertEq(s, address(0), "no supply call recorded");
        assertEq(amount, 0);
        assertFalse(gateway.usingAsCollateral(safe, asset), "collateral flag untouched");
    }

    // The shortfall sizing pulls only the part not already loose, capped at what the safe supplied.
    function test_withdrawShortfall_pullsCappedShortfall() public {
        gateway.setSuppliedOf(safe, asset, 30e6);
        // Needs AMOUNT (100e6), 60e6 already loose: shortfall 40e6, but only 30e6 supplied to pull.
        harness.withdrawShortfall(safe, asset, AMOUNT, 60e6);

        (address s, address a, uint256 amount, address to) = gateway.lastWithdraw();
        assertEq(s, safe);
        assertEq(a, asset);
        assertEq(amount, 30e6);
        assertEq(to, safe);
    }

    // No withdraw when the loose balance already covers the amount.
    function test_withdrawShortfall_noOpWhenCovered() public {
        gateway.setSuppliedOf(safe, asset, 30e6);
        harness.withdrawShortfall(safe, asset, AMOUNT, AMOUNT);

        (address s,, uint256 amount,) = gateway.lastWithdraw();
        assertEq(s, address(0), "no withdraw call recorded");
        assertEq(amount, 0);
    }

    // Off the gateway engine (legacy safe) the withdraw bookend is a no-op: nothing is supplied on Aave.
    function test_withdraw_noOpWhenOffGatewayEngine() public {
        harness.setOnGatewayEngine(false);
        gateway.setSuppliedOf(safe, asset, AMOUNT);
        harness.withdrawShortfall(safe, asset, AMOUNT, 0);

        (address s,, uint256 amount,) = gateway.lastWithdraw();
        assertEq(s, address(0), "no withdraw call recorded");
        assertEq(amount, 0);
    }

    // The withdraw bookend is ENGINE-gated, not lend-active-gated: an opted-out safe (e.g. a matured
    // opt-out whose unwind open borrows still block) can hold supplied funds, and reclaiming them is an
    // exit op the repayment paths depend on (repayUsingLiquidUSD sourcing supplied LiquidUSD).
    function test_withdraw_stillPullsForOptedOutSafeOnEngine() public {
        harness.setLendActive(false); // opted out...
        gateway.setSuppliedOf(safe, asset, AMOUNT); // ...but funds still supplied on Aave
        harness.withdrawShortfall(safe, asset, AMOUNT, 0);

        (address s, address a, uint256 amount,) = gateway.lastWithdraw();
        assertEq(s, safe, "withdraw pulled for the opted-out safe");
        assertEq(a, asset);
        assertEq(amount, AMOUNT);
    }

    // When lend is disabled, the resupply bookend is a no-op: the output stays in the safe, nothing goes to Aave.
    function test_resupply_noOpWhenLendOptedOut() public {
        harness.setLendActive(false);
        harness.resupplyToGateway(safe, asset, AMOUNT);

        (address s,, uint256 amount,) = gateway.lastSupply();
        assertEq(s, address(0), "no supply call recorded");
        assertEq(amount, 0);
        assertFalse(gateway.usingAsCollateral(safe, asset), "collateral flag untouched");
    }

    // ----------------------------------------------------------------- floor check gating

    uint256 constant HF_BEFORE = 1.02e18;

    /// @dev Simulates the gateway rejecting the end state, whatever rule it applies internally.
    function _mockFloorViolated() internal {
        vm.mockCallRevert(address(gateway), abi.encodeWithSelector(ILendGateway.ensureMinHealthFactorNotWorsened.selector, safe, HF_BEFORE), "below floor");
    }

    // The floor check runs for a fully active gateway safe: a rejected end state reverts the operation.
    function test_floor_revertsForActiveSafeBelowFloor() public {
        _mockFloorViolated();
        vm.expectRevert("below floor");
        harness.ensureGatewayFloor(safe, HF_BEFORE);
    }

    // The floor check is ENGINE-gated like the withdraw bookend, not lend-active-gated. An opted-out safe
    // with a live Aave position (a matured opt-out whose unwind open borrows still block) can pull collateral
    // through the front bookend with no resupply behind it; the floor must still bind that extraction, or the
    // position can be parked at Aave's raw 1.0 boundary. Repayment flows never call this check, so the safe
    // can always still repay its way out of the blocked opt-out.
    function test_floor_revertsForOptedOutSafeOnEngine() public {
        harness.setLendActive(false); // opted out, but still on the gateway engine with a live position
        _mockFloorViolated();
        vm.expectRevert("below floor");
        harness.ensureGatewayFloor(safe, HF_BEFORE);
    }

    // Off the gateway engine (legacy safe) there is no Aave position to protect: the check is a no-op
    // even when the gateway would reject the end state.
    function test_floor_noOpOffGatewayEngine() public {
        harness.setOnGatewayEngine(false);
        _mockFloorViolated();
        harness.ensureGatewayFloor(safe, HF_BEFORE); // must not revert
    }

    // The pre-operation snapshot the floor check compares against is read for a gateway safe and inert
    // (zero) off the engine, where a snapshot could only ever tighten a check that does not run.
    function test_floor_snapshotReadsGatewayHealthOnEngineOnly() public {
        gateway.setHealthFactor(safe, HF_BEFORE);
        assertEq(harness.gatewayHealthFactor(safe), HF_BEFORE, "snapshot reads the gateway health factor");

        harness.setOnGatewayEngine(false);
        assertEq(harness.gatewayHealthFactor(safe), 0, "inert off the gateway engine");
    }
}
