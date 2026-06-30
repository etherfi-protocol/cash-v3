// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { IGateway } from "../../../src/interfaces/IGateway.sol";
import { MockGateway } from "../../../src/mocks/MockGateway.sol";
import { ModuleGatewaySandwich } from "../../../src/modules/ModuleGatewaySandwich.sol";

/// @notice Exposes the base's internal bookends so they can be called directly in tests
contract SandwichHarness is ModuleGatewaySandwich {
    constructor(address _gateway, uint256 _minHealthFactor) ModuleGatewaySandwich(_gateway, _minHealthFactor) { }

    function withdrawFromGateway(address safe, address asset, uint256 amount) external {
        _withdrawFromGateway(safe, asset, amount);
    }

    function resupplyToGateway(address safe, address asset, uint256 amount) external {
        _resupplyToGateway(safe, asset, amount);
    }

    /// @notice A guarded withdraw-resupply operation, mirroring how a module brackets its action
    function runSandwich(address safe, address asset, uint256 amount) external guardsHealth(safe) {
        _withdrawFromGateway(safe, asset, amount);
        _resupplyToGateway(safe, asset, amount);
    }
}

contract ModuleGatewaySandwichTest is Test {
    MockGateway gateway;
    SandwichHarness harness;

    uint256 constant MIN_HEALTH_FACTOR = 1e18;
    uint256 constant AMOUNT = 100e6;
    address safe = makeAddr("safe");
    address asset = makeAddr("asset");

    function setUp() public {
        gateway = new MockGateway();
        harness = new SandwichHarness(address(gateway), MIN_HEALTH_FACTOR);
    }

    function _setHealthFactor(uint256 healthFactor) internal {
        gateway.setAccountData(safe, IGateway.AccountData({ collateralUsd: 0, debtUsd: 0, availableBorrowsUsd: 0, healthFactor: healthFactor }));
    }

    // A zero gateway address is rejected at deployment.
    function test_constructor_revertsOnZeroGateway() public {
        vm.expectRevert(ModuleGatewaySandwich.InvalidGateway.selector);
        new SandwichHarness(address(0), MIN_HEALTH_FACTOR);
    }

    // The withdraw bookend routes to the safe and does not guard health; Aave guards the withdraw itself.
    function test_withdraw_routesToSafe() public {
        harness.withdrawFromGateway(safe, asset, AMOUNT);

        (address s, address a, uint256 amount, address to) = gateway.lastWithdraw();
        assertEq(s, safe);
        assertEq(a, asset);
        assertEq(amount, AMOUNT);
        assertEq(to, safe);
    }

    // The resupply bookend supplies the asset back to Aave and marks it as collateral, with no health guard of its own.
    function test_resupply_suppliesAndSetsCollateral() public {
        harness.resupplyToGateway(safe, asset, AMOUNT);

        (address s, address a, uint256 amount, address to) = gateway.lastSupply();
        assertEq(s, safe);
        assertEq(a, asset);
        assertEq(amount, AMOUNT);
        assertEq(to, address(0));
        assertTrue(gateway.usingAsCollateral(safe, asset));
    }

    // The guarded operation runs both bookends and passes at exactly minHealthFactor.
    function test_guardedOperation_passesAtMinHealthFactor() public {
        _setHealthFactor(MIN_HEALTH_FACTOR);
        harness.runSandwich(safe, asset, AMOUNT);

        (address ws,,, address wto) = gateway.lastWithdraw();
        assertEq(ws, safe);
        assertEq(wto, safe);
        assertTrue(gateway.usingAsCollateral(safe, asset));
    }

    // The guard reverts when the completed operation leaves the safe's health factor below the floor.
    function test_guardedOperation_revertsBelowMinHealthFactor() public {
        _setHealthFactor(MIN_HEALTH_FACTOR - 1);
        vm.expectRevert(ModuleGatewaySandwich.OperationBreachesHealth.selector);
        harness.runSandwich(safe, asset, AMOUNT);
    }
}
