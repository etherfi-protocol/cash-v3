// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { RollbackCashLendDev } from "../../../scripts/lend/RollbackCashLendDev.s.sol";
import { IAaveV4Spoke } from "../../../src/interfaces/IAaveV4Spoke.sol";

/// @dev Exposes the rollback script's internal checks so they can be tested without broadcasting transactions.
contract RollbackCashLendDevHarness is RollbackCashLendDev {
    /// @dev Runs the checks used by the safe, clean-only rollback mode.
    function enforceClean(bool hasNonCleanSafe, uint256 supplyUsd, uint256 debtUsd) external pure {
        _enforceMode(RollbackMode.CleanOnly, hasNonCleanSafe, supplyUsd, debtUsd);
    }

    /// @dev Runs the checks used by force mode, which logs problems instead of reverting.
    function enforceForce(bool hasNonCleanSafe, uint256 supplyUsd, uint256 debtUsd) external pure {
        _enforceMode(RollbackMode.ForceImplementations, hasNonCleanSafe, supplyUsd, debtUsd);
    }

    /// @dev Exposes the calculation of total supplied and borrowed USD across the Spoke.
    function spokeTotalsUsd(IAaveV4Spoke spoke) external view returns (uint256, uint256) {
        return _spokeTotalsUsd(spoke);
    }

    /// @dev Exposes the hash used to detect changes to a Safe's Aave position.
    function positionHash(IAaveV4Spoke spoke, address safe) external view returns (bytes32) {
        return _positionHash(spoke, safe);
    }

    /// @dev Checks that an implementation is either the Lend version or the original version.
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

/// @dev Minimal Aave Spoke implementing only the reserve and position reads used by these tests.
contract MockRollbackSpoke {
    address public immutable ORACLE;
    IAaveV4Spoke.Reserve[] internal _reserves;
    uint256[] internal _supplied;
    uint256[] internal _debt;
    mapping(uint256 => mapping(address => uint256)) internal _positionWords;
    mapping(uint256 => mapping(address => bool)) internal _usingAsCollateral;
    mapping(uint256 => mapping(address => bool)) internal _borrowed;

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

    /// @dev Changes one mock position value so tests can confirm the position hash changes.
    function setPositionWord(uint256 reserveId, address safe, uint256 value) external {
        _positionWords[reserveId][safe] = value;
    }

    /// @dev Changes the mock collateral and borrowed flags included in the position hash.
    function setUserReserveStatus(uint256 reserveId, address safe, bool usingAsCollateral, bool borrowed) external {
        _usingAsCollateral[reserveId][safe] = usingAsCollateral;
        _borrowed[reserveId][safe] = borrowed;
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

    /// @dev Returns stable mock position data used by the rollback position hash.
    function getUserPosition(uint256 reserveId, address safe) external view returns (uint256) {
        return _positionWords[reserveId][safe];
    }

    /// @dev Returns the mock collateral and borrowed flags used by the rollback position hash.
    function getUserReserveStatus(uint256 reserveId, address safe) external view returns (bool, bool) {
        return (_usingAsCollateral[reserveId][safe], _borrowed[reserveId][safe]);
    }
}

/// @dev Unit tests for rollback safety modes, Spoke valuation, resumability, and position snapshots.
contract RollbackCashLendDevTest is Test {
    // Aave's test oracle reports USD prices with 8 decimals.
    uint256 internal constant USD = 1e8;

    RollbackCashLendDevHarness internal harness;
    MockRollbackOracle internal oracle;
    MockRollbackSpoke internal spoke;

    /// @dev Creates a fresh rollback harness, oracle, price source, and Spoke before each test.
    function setUp() public {
        harness = new RollbackCashLendDevHarness();
        oracle = new MockRollbackOracle();
        spoke = new MockRollbackSpoke(address(oracle));
    }

    /// @dev Clean-only mode allows supply and debt exactly at the agreed $100 limits.
    function test_cleanOnlyAcceptsExactHundredDollarBounds() public view {
        harness.enforceClean(false, 100 * USD, 100 * USD);
    }

    /// @dev Clean-only mode stops when a specified pilot Safe still has an Aave position.
    function test_cleanOnlyRejectsNonCleanPilotSafe() public {
        vm.expectRevert("pilot Safe has Aave supply or debt");
        harness.enforceClean(true, 0, 0);
    }

    /// @dev Clean-only mode stops when total Spoke supply exceeds $100.
    function test_cleanOnlyRejectsSupplyAboveHundredDollars() public {
        vm.expectRevert("Spoke supply exceeds $100");
        harness.enforceClean(false, 100 * USD + 1, 0);
    }

    /// @dev Clean-only mode stops when total Spoke debt exceeds $100.
    function test_cleanOnlyRejectsDebtAboveHundredDollars() public {
        vm.expectRevert("Spoke debt exceeds $100");
        harness.enforceClean(false, 0, 100 * USD + 1);
    }

    /// @dev Force mode continues when pilot positions or aggregate values exceed the clean limits.
    function test_forceModeAcceptsEveryGuardFailure() public view {
        harness.enforceForce(true, type(uint256).max, type(uint256).max);
    }

    /// @dev A resumed rollback accepts steps that are still on Lend or already restored.
    function test_resumableRollbackAcceptsLendOrOriginalReferences() public view {
        harness.requireRollbackReference(address(1), address(1), address(2));
        harness.requireRollbackReference(address(2), address(1), address(2));
    }

    /// @dev A rollback stops if another implementation was deployed outside this rollout.
    function test_resumableRollbackRejectsUnknownReference() public {
        vm.expectRevert("implementation is outside rollback transition");
        harness.requireRollbackReference(address(3), address(1), address(2));
    }

    /// @dev Empty pilot lists can be written to and read from the rollback snapshot JSON.
    function test_emptyPilotSnapshotArraysRoundTrip() public {
        string memory object = "empty-rollback-snapshot-test";
        address[] memory safes = new address[](0);
        bytes32[] memory hashes = new bytes32[](0);
        vm.serializeAddress(object, "pilotSafes", safes);
        string memory json = vm.serializeBytes32(object, "positionHashes", hashes);

        assertEq(stdJson.readAddressArray(json, ".pilotSafes").length, 0);
        assertEq(stdJson.readBytes32Array(json, ".positionHashes").length, 0);
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

    /// @dev Position snapshots change when collateral or borrowed status changes without changing balances.
    function test_positionHashCoversCollateralAndBorrowStatus() public {
        address safe = address(0x5AFE);
        spoke.addReserve(address(0xA1), 6, 0, 0);
        bytes32 beforeHash = harness.positionHash(IAaveV4Spoke(address(spoke)), safe);

        spoke.setUserReserveStatus(0, safe, true, false);
        bytes32 collateralHash = harness.positionHash(IAaveV4Spoke(address(spoke)), safe);
        spoke.setUserReserveStatus(0, safe, true, true);
        bytes32 borrowedHash = harness.positionHash(IAaveV4Spoke(address(spoke)), safe);

        assertNotEq(beforeHash, collateralHash);
        assertNotEq(collateralHash, borrowedHash);
    }

    /// @dev Position snapshots include every Spoke reserve, even if the gateway did not register it.
    function test_positionHashCoversReservesAddedOutsideGatewayRegistry() public {
        address safe = address(0x5AFE);
        spoke.addReserve(address(0xA1), 6, 0, 0);
        spoke.addReserve(address(0xA2), 18, 0, 0);
        bytes32 beforeHash = harness.positionHash(IAaveV4Spoke(address(spoke)), safe);

        spoke.setPositionWord(1, safe, 1);
        bytes32 afterHash = harness.positionHash(IAaveV4Spoke(address(spoke)), safe);

        assertNotEq(beforeHash, afterHash);
    }
}
