// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { RollbackCashLendDev } from "../../../scripts/lend/RollbackCashLendDev.s.sol";
import { IAaveV4Spoke } from "../../../src/interfaces/IAaveV4Spoke.sol";

/// @dev Exposes the rollback script's internal checks so they can be tested without broadcasting transactions.
contract RollbackCashLendDevHarness is RollbackCashLendDev {
    /// @dev Runs the aggregate fund limits applied before a rollback broadcasts.
    function requireFundsWithinLimits(uint256 supplyUsd, uint256 debtUsd) external pure {
        _requireFundsWithinLimits(supplyUsd, debtUsd);
    }

    /// @dev Exposes the calculation of total supplied and borrowed USD across the Spoke.
    function spokeTotalsUsd(IAaveV4Spoke spoke) external view returns (uint256, uint256) {
        return _spokeTotalsUsd(spoke);
    }

    /// @dev Checks that an implementation is either the Lend version or the baseline version.
    function requireRollbackReference(address current, address lend, address original) external pure {
        _requireRollbackReference(current, lend, original);
    }
}

/// @dev Minimal Aave oracle that returns test prices.
contract MockRollbackOracle {
    uint8 public decimals = 8;
    uint256[] internal _prices;

    /// @dev Sets the prices returned by getReservesPrices.
    function setPrices(uint256[] memory prices) external {
        _prices = prices;
    }

    /// @dev Returns configured prices.
    function getReservesPrices(uint256[] calldata) external view returns (uint256[] memory) {
        return _prices;
    }
}

/// @dev Minimal Aave Spoke implementing only the reserve reads used by the Spoke valuation.
contract MockRollbackSpoke {
    address public immutable ORACLE;
    IAaveV4Spoke.Reserve[] internal _reserves;
    uint256[] internal _supplied;
    uint256[] internal _debt;

    /// @dev Sets the oracle used to value all mock reserves.
    constructor(address oracle_) {
        ORACLE = oracle_;
    }

    /// @dev Adds a reserve with configurable decimals, total supply, and total debt.
    function addReserve(address underlying, uint8 decimals_, uint256 supplied, uint256 debt) external {
        _reserves.push(IAaveV4Spoke.Reserve({ underlying: underlying, hub: address(1), assetId: uint16(_reserves.length), decimals: decimals_, collateralRisk: 0, flags: 0, dynamicConfigKey: 0 }));
        _supplied.push(supplied);
        _debt.push(debt);
    }

    /// @dev Returns the number of mock reserves.
    function getReserveCount() external view returns (uint256) {
        return _reserves.length;
    }

    /// @dev Returns one mock reserve's metadata.
    function getReserve(uint256 reserveId) external view returns (IAaveV4Spoke.Reserve memory) {
        return _reserves[reserveId];
    }

    /// @dev Returns the total supplied amount configured for a reserve.
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256) {
        return _supplied[reserveId];
    }

    /// @dev Returns the total debt configured for a reserve.
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256) {
        return _debt[reserveId];
    }
}

/// @dev Unit tests for the rollback fund limits, Spoke valuation, and resumability check.
contract RollbackCashLendDevTest is Test {
    // Aave's test oracle reports USD prices with 8 decimals.
    uint256 internal constant USD = 1e8;

    RollbackCashLendDevHarness internal harness;
    MockRollbackOracle internal oracle;
    MockRollbackSpoke internal spoke;

    /// @dev Creates a fresh rollback harness, oracle, and Spoke before each test.
    function setUp() public {
        harness = new RollbackCashLendDevHarness();
        oracle = new MockRollbackOracle();
        spoke = new MockRollbackSpoke(address(oracle));
    }

    /// @dev The fund check allows supply and debt exactly at the agreed $100 limits.
    function test_fundCheckAcceptsExactHundredDollarBounds() public view {
        harness.requireFundsWithinLimits(100 * USD, 100 * USD);
    }

    /// @dev The fund check stops when total Spoke supply exceeds $100.
    function test_fundCheckRejectsSupplyAboveHundredDollars() public {
        vm.expectRevert("Spoke supply exceeds $100");
        harness.requireFundsWithinLimits(100 * USD + 1, 0);
    }

    /// @dev The fund check stops when total Spoke debt exceeds $100.
    function test_fundCheckRejectsDebtAboveHundredDollars() public {
        vm.expectRevert("Spoke debt exceeds $100");
        harness.requireFundsWithinLimits(0, 100 * USD + 1);
    }

    /// @dev A resumed rollback accepts references that are still on Lend or already restored.
    function test_resumableRollbackAcceptsLendOrOriginalReferences() public view {
        harness.requireRollbackReference(address(1), address(1), address(2));
        harness.requireRollbackReference(address(2), address(1), address(2));
    }

    /// @dev A rollback stops if another implementation was deployed outside this rollout.
    function test_resumableRollbackRejectsUnknownReference() public {
        vm.expectRevert("implementation is outside rollback transition");
        harness.requireRollbackReference(address(3), address(1), address(2));
    }

    /// @dev Spoke valuation rounds up so a value just above $100 cannot pass as exactly $100.
    function test_spokeValuationRoundsUpAtBoundary() public {
        spoke.addReserve(address(0xA1), 6, 100e6 + 1, 100e6 + 1);
        uint256[] memory prices = new uint256[](1);
        prices[0] = USD;
        oracle.setPrices(prices);

        (uint256 supplyUsd, uint256 debtUsd) = harness.spokeTotalsUsd(IAaveV4Spoke(address(spoke)));
        assertEq(supplyUsd, 100 * USD + 100);
        assertEq(debtUsd, 100 * USD + 100);
    }
}
