// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626Mock } from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { StockMigrationModule } from "../../../../../src/migration/StockMigrationModule.sol";
import { IAaveV4PriceFeed } from "../../../../../src/interfaces/IAaveV4PriceFeed.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { UpgradeableProxy, PausableUpgradeable } from "../../../../../src/utils/UpgradeableProxy.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/// @dev Fixed USD price for the stand-in and the wrapper so both reserves value collateral identically
contract FixedStockFeed is IAaveV4PriceFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "SPY / USD";
    }

    function latestAnswer() external pure returns (int256) {
        return 500e8;
    }
}

/**
 * @title StockMigrationModuleGatewayTest
 * @notice Swaps a safe's stand-in stock for its wrapper against the real LendGateway and a real Aave v4
 *         instance: supplied positions move reserve without the health factor changing, loose balances are
 *         replaced and resupplied.
 */
contract StockMigrationModuleGatewayTest is CashGatewayTestSetup {
    StockMigrationModule internal module;
    MockERC20 internal standIn;
    MockERC20 internal raw;
    ERC4626Mock internal wrapper;

    address internal keeper = makeAddr("keeper");
    address internal admin = makeAddr("migrationAdmin");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant SEED = 100e18;
    uint256 internal constant SUPPLIED = 10e18;
    uint256 internal constant LOOSE = 3e18;
    uint256 internal constant DEBT = 1_000e6;

    function setUp() public override {
        super.setUp();

        standIn = new MockERC20("iwSPYx", "iwSPYx", 18);
        raw = new MockERC20("SPYx", "SPYx", 18);
        wrapper = new ERC4626Mock(address(raw));
        address feed = address(new FixedStockFeed());
        uint256 standInId = _addAaveReserve(address(standIn), feed, 7300, false);
        uint256 wrapperId = _addAaveReserve(address(wrapper), feed, 7300, false);

        address impl = address(new StockMigrationModule(address(dataProvider)));
        module = StockMigrationModule(address(new UUPSProxy(impl, abi.encodeWithSelector(StockMigrationModule.initialize.selector, address(roleRegistry)))));
        _enableModule(address(module));

        vm.startPrank(owner);
        gw.setReserveId(address(standIn), standInId);
        gw.setReserveId(address(wrapper), wrapperId);
        gw.setDriver(address(module), true);
        roleRegistry.grantRole(module.ETHER_FI_WALLET_ROLE(), keeper);
        roleRegistry.grantRole(module.STOCK_MIGRATION_MODULE_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(roleRegistry.PAUSER(), owner);
        vm.stopPrank();

        vm.prank(admin);
        module.setSwapPairs(_addr1(address(standIn)), _addr1(address(wrapper)));

        // Seed the module with real wrapper shares backed by raw stock, as treasury would
        raw.mint(address(module), SEED);
        vm.startPrank(address(module));
        raw.approve(address(wrapper), SEED);
        wrapper.deposit(SEED, address(module));
        vm.stopPrank();
    }

    function test_migrate_suppliedPosition_keepsHealthFactor() public {
        _buildGatewayPosition(address(safe), address(standIn), SUPPLIED, address(usdc), DEBT);
        uint256 healthBefore = gw.healthFactor(address(safe));

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit StockMigrationModule.Migrated(address(safe), address(standIn), address(wrapper), SUPPLIED, 0);
        (uint256 supplied, uint256 loose) = module.migrate(address(safe), address(standIn));

        assertEq(supplied, SUPPLIED);
        assertEq(loose, 0);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(wrapper)), SUPPLIED, 1, "wrapper not supplied");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(standIn)), 0, 1, "stand-in still supplied");
        assertEq(standIn.balanceOf(address(module)), SUPPLIED, "stand-in not collected");
        assertEq(wrapper.balanceOf(address(safe)), 0, "wrapper left loose");
        assertEq(gw.healthFactor(address(safe)), healthBefore, "health factor moved");
    }

    function test_migrate_looseBalance_resuppliesWrapper() public {
        deal(address(standIn), address(safe), LOOSE);

        vm.prank(keeper);
        module.migrate(address(safe), address(standIn));

        assertEq(standIn.balanceOf(address(safe)), 0);
        assertEq(standIn.balanceOf(address(module)), LOOSE);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(wrapper)), LOOSE, 1, "wrapper not resupplied");
        assertEq(wrapper.balanceOf(address(module)), SEED - LOOSE);
    }

    function test_migrate_bothLegs() public {
        _supplyToGateway(address(safe), address(standIn), SUPPLIED);
        deal(address(standIn), address(safe), LOOSE);

        vm.prank(keeper);
        (uint256 supplied, uint256 loose) = module.migrate(address(safe), address(standIn));

        assertEq(supplied, SUPPLIED);
        assertEq(loose, LOOSE);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(wrapper)), SUPPLIED + LOOSE, 2);
        assertEq(standIn.balanceOf(address(module)), SUPPLIED + LOOSE);
    }

    function test_migrate_legacySafe_wrapperStaysLoose() public {
        _forceLegacyEngine(address(safe));
        deal(address(standIn), address(safe), LOOSE);

        vm.prank(keeper);
        module.migrate(address(safe), address(standIn));

        assertEq(wrapper.balanceOf(address(safe)), LOOSE, "wrapper must stay loose for a legacy safe");
        assertEq(standIn.balanceOf(address(module)), LOOSE);
    }

    function test_migrate_reverts_whenPendingWithdrawal() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.mockCall(address(cashModule), abi.encodeWithSelector(ICashModule.getPendingWithdrawalAmount.selector, address(safe), address(standIn)), abi.encode(uint256(1)));

        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.PendingWithdrawal.selector);
        module.migrate(address(safe), address(standIn));
    }

    function test_migrate_reverts_whenNothingToMigrate() public {
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.NothingToMigrate.selector);
        module.migrate(address(safe), address(standIn));
    }

    function test_migrate_reverts_whenSeedShort() public {
        deal(address(standIn), address(safe), SEED + 1);
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.InsufficientSeed.selector);
        module.migrate(address(safe), address(standIn));
    }

    function test_migrate_reverts_whenPairNotSet() public {
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.PairNotSet.selector);
        module.migrate(address(safe), address(raw));
    }

    function test_migrate_reverts_whenNotKeeper() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.prank(admin);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.migrate(address(safe), address(standIn));
    }

    function test_migrate_reverts_whenPaused() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.prank(owner);
        module.pause();
        vm.prank(keeper);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        module.migrate(address(safe), address(standIn));
    }

    function test_migrateSelf_reverts_whenNotSelf() public {
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.OnlySelf.selector);
        module.migrateSelf(address(safe), address(standIn));
    }

    function test_migrateMany_skipsFailuresAndContinues() public {
        deal(address(standIn), address(safe), LOOSE);
        address[] memory safes = new address[](3);
        safes[0] = makeAddr("notASafe");
        safes[1] = address(safe);
        safes[2] = address(safe); // nothing left after the first pass

        vm.prank(keeper);
        vm.expectEmit(true, true, false, false);
        emit StockMigrationModule.MigrateSkipped(safes[0], address(standIn), "");
        uint256 migrated = module.migrateMany(safes, address(standIn));

        assertEq(migrated, 1);
        assertEq(standIn.balanceOf(address(module)), LOOSE);
    }

    function test_setSwapPairs_reverts_whenNotAdmin() public {
        vm.prank(keeper);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.setSwapPairs(_addr1(address(standIn)), _addr1(address(wrapper)));
    }

    function test_sweep_adminOnly_movesCollectedAndSeed() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.prank(keeper);
        module.migrate(address(safe), address(standIn));

        vm.prank(keeper);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.sweep(address(standIn), treasury, 0);

        vm.startPrank(admin);
        module.sweep(address(standIn), treasury, 0);
        module.sweep(address(wrapper), treasury, 1e18);
        vm.stopPrank();

        assertEq(standIn.balanceOf(treasury), LOOSE);
        assertEq(wrapper.balanceOf(treasury), 1e18);
        assertEq(wrapper.balanceOf(address(module)), SEED - LOOSE - 1e18);
    }
}
