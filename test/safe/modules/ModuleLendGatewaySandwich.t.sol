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

    function withdrawShortfall(address safe, address asset, uint256 amount, uint256 looseAvailable) external {
        _withdrawShortfall(safe, asset, amount, looseAvailable);
    }

    function resupplyToGateway(address safe, address asset, uint256 amount) external {
        _resupplyToGateway(safe, asset, amount);
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

    // When lend is disabled for the safe, the withdraw bookend is a no-op: its assets already sit in the safe.
    function test_withdraw_noOpWhenLendOptedOut() public {
        harness.setLendActive(false);
        gateway.setSuppliedOf(safe, asset, AMOUNT);
        harness.withdrawShortfall(safe, asset, AMOUNT, 0);

        (address s,, uint256 amount,) = gateway.lastWithdraw();
        assertEq(s, address(0), "no withdraw call recorded");
        assertEq(amount, 0);
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
}
