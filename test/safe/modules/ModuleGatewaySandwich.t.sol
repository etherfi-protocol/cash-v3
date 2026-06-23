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

    // Withdraws to the safe and passes the guard at exactly minHealthFactor.
    function test_withdraw_routesToSafeAndPassesAtMinHealthFactor() public {
        _setHealthFactor(MIN_HEALTH_FACTOR);
        harness.withdrawFromGateway(safe, asset, AMOUNT);

        (address s, address a, uint256 amount, address to) = gateway.lastWithdraw();
        assertEq(s, safe);
        assertEq(a, asset);
        assertEq(amount, AMOUNT);
        assertEq(to, safe);
    }

    function test_withdraw_revertsBelowMinHealthFactor() public {
        _setHealthFactor(MIN_HEALTH_FACTOR - 1);
        vm.expectRevert(ModuleGatewaySandwich.WithdrawBreachesHealth.selector);
        harness.withdrawFromGateway(safe, asset, AMOUNT);
    }

    function test_resupply_suppliesAndSetsCollateral() public {
        harness.resupplyToGateway(safe, asset, AMOUNT);

        (address s, address a, uint256 amount, address to) = gateway.lastSupply();
        assertEq(s, safe);
        assertEq(a, asset);
        assertEq(amount, AMOUNT);
        assertEq(to, address(0));
        assertTrue(gateway.usingAsCollateral(safe, asset));
    }
}
