// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerStorageContract } from "../../src/debt-manager/DebtManagerStorageContract.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { IGateway } from "../../src/interfaces/IGateway.sol";
import { Gateway } from "../../src/modules/gateway/Gateway.sol";
import { ChainlinkCompositePriceFeed } from "../../src/oracle/ChainlinkCompositePriceFeed.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { CashModuleTestSetup } from "../safe/modules/cash/CashModuleTestSetup.t.sol";
import { AaveV4Fixture } from "./helpers/AaveV4Fixture.sol";

/**
 * @title DebtManagerMigrationTest
 * @notice Fork tests for DebtManager.migrateToAave: a legacy Safe position (weETH collateral + USDC debt on
 *         DebtManager) migrates atomically to a REAL Aave v4 instance (deployed in-test on an Optimism fork)
 *         via the gateway — no flash loan. Aave's weETH LTV is set below DebtManager's so the LTV-fit path
 *         is exercised.
 * @dev Run with: FOUNDRY_PROFILE=aave TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/gateway/DebtManagerMigration.t.sol
 */
contract DebtManagerMigrationTest is CashModuleTestSetup, AaveV4Fixture {
    DebtManagerCore internal dm;
    Gateway internal gw;
    address internal migrator = makeAddr("migrationRunner");

    uint256 internal usdcReserveId;
    uint256 internal weethReserveId;

    uint16 internal constant AAVE_WEETH_LTV = 3000; // below DebtManager's 50%, to exercise the LTV-fit guard

    function setUp() public override {
        super.setUp();
        dm = DebtManagerCore(address(debtManager));

        // Real Aave v4 instance on the fork
        _deployAaveV4();
        address weethSource = address(new ChainlinkCompositePriceFeed(IAggregatorV3(weEthWethOracle), IAggregatorV3(ethUsdcOracle), 8, 30 days, 30 days, "weETH / USD"));
        weethReserveId = _addAaveReserve(address(weETH), weethSource, AAVE_WEETH_LTV, false);
        usdcReserveId = _addAaveReserve(address(usdc), usdcUsdOracle, 8000, true);

        // Gateway proxy + wiring
        address gwImpl = address(new Gateway(address(dataProvider), address(spoke)));
        gw = Gateway(address(new UUPSProxy(gwImpl, abi.encodeWithSelector(Gateway.initialize.selector, address(roleRegistry)))));

        vm.startPrank(owner);
        roleRegistry.grantRole(gw.GATEWAY_ADMIN_ROLE(), owner);
        dataProvider.configureModules(_addr1(address(gw)), _bool1(true));
        gw.setReserveId(address(weETH), weethReserveId);
        gw.setReserveId(address(usdc), usdcReserveId);
        gw.setDriver(address(dm), true); // DebtManager drives the gateway during migration
        // DebtManager migration wiring: point it at the gateway and authorize the migration runner
        roleRegistry.grantRole(DEBT_MANAGER_ADMIN_ROLE, migrator);
        vm.stopPrank();

        vm.prank(migrator);
        dm.setGateway(address(gw));

        _enableModule(address(gw));
        _activateAavePositionManager(address(gw));
    }

    // ----------------------------------------------------------------- happy path

    function test_migrateToAave_atomic_noFlashLoan() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Legacy position: 10 weETH collateral, borrow a modest fraction that fits Aave's 30% LTV
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4; // ~12.5% of collateral value
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdc)), borrowAmt, 1, "legacy debt created");

        uint256 dmUsdcBefore = usdc.balanceOf(address(debtManager));

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        // Legacy debt closed and Safe flagged migrated
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "legacy debt cleared");
        assertTrue(dm.hasMigratedToAave(address(safe)), "marked migrated");
        // Position now lives on Aave: same collateral, same debt size
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 10 ether, 3, "collateral on Aave");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowAmt, 1e6, "debt on Aave");
        assertGt(gw.getAccountData(address(safe)).healthFactor, 1e18, "healthy on Aave");
        // Collateral left the Safe
        assertEq(weETH.balanceOf(address(safe)), 0, "safe collateral moved");
        // No funds stranded: gateway holds nothing; the Aave borrow replenished DebtManager's lent-out USDC
        assertEq(weETH.balanceOf(address(gw)), 0, "no stranded weETH");
        assertEq(usdc.balanceOf(address(gw)), 0, "no stranded USDC");
        assertApproxEqAbs(usdc.balanceOf(address(debtManager)), dmUsdcBefore + borrowAmt, 1e6, "DebtManager USDC replenished");
    }

    // ----------------------------------------------------------------- reverts

    function test_migrateToAave_revertsWhenExceedsAaveLtv() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Borrow ~90% of DebtManager's max: fits DebtManager's 50% LTV, exceeds Aave's 30%
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = (dm.getMaxBorrowAmount(address(safe), true) * 9) / 10;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        vm.expectRevert(DebtManagerStorageContract.PositionExceedsAaveLtv.selector);
        dm.migrateToAave(address(safe));
    }

    function test_migrateToAave_revertsWhenInsufficientAaveLiquidity() public {
        // No Aave liquidity seeded → the reserve cannot fund the borrow
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        vm.expectRevert(abi.encodeWithSelector(DebtManagerStorageContract.InsufficientAaveLiquidity.selector, address(usdc)));
        dm.migrateToAave(address(safe));
    }

    function test_migrateToAave_noDebt_marksMigratedWithoutReverting() public {
        deal(address(weETH), address(safe), 10 ether); // collateral but no debt
        assertFalse(dm.hasMigratedToAave(address(safe)));

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        assertTrue(dm.hasMigratedToAave(address(safe)), "marked migrated");
        // Nothing moved: no debt to migrate, so the collateral stays in the Safe
        assertEq(weETH.balanceOf(address(safe)), 10 ether, "collateral untouched");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "nothing supplied to Aave");
    }

    function test_migrateToAave_onlyDebtManagerAdmin() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(makeAddr("notMigrator"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        dm.migrateToAave(address(safe));
    }

    function test_migratedSafe_cannotBorrowOrRepayOnDebtManager() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));
        assertTrue(dm.hasMigratedToAave(address(safe)));

        // Legacy borrow is frozen for a migrated Safe
        vm.prank(address(safe));
        vm.expectRevert(DebtManagerStorageContract.AlreadyMigratedToAave.selector);
        debtManager.borrow(BinSponsor.Reap, address(usdc), 1e6);

        // Legacy repay is frozen for a migrated Safe
        vm.expectRevert(DebtManagerStorageContract.AlreadyMigratedToAave.selector);
        debtManager.repay(address(safe), address(usdc), 1e6);
    }

    // ----------------------------------------------------------------- helpers

    function _enableModule(address module) internal {
        address[] memory modules = _addr1(module);
        bool[] memory shouldWhitelist = _bool1(true);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, shouldWhitelist, setupData);
    }

    function _addr1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _bool1(bool b) internal pure returns (bool[] memory arr) {
        arr = new bool[](1);
        arr[0] = b;
    }
}
