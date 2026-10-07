// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626Mock } from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { DebtManagerStorageContract } from "../../../../../src/debt-manager/DebtManagerStorageContract.sol";
import { BinSponsor, ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { StockMigrationModule } from "../../../../../src/migration/StockMigrationModule.sol";
import { IAaveV4PriceFeed } from "../../../../../src/interfaces/IAaveV4PriceFeed.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { PriceProvider } from "../../../../../src/oracle/PriceProvider.sol";
import { RoleRegistry } from "../../../../../src/role-registry/RoleRegistry.sol";
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
    using MessageHashUtils for bytes32;

    StockMigrationModule internal module;
    MockERC20 internal standIn;
    MockERC20 internal raw;
    ERC4626Mock internal wrapper;
    address internal stockFeed;

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
        stockFeed = address(new FixedStockFeed());
        uint256 standInId = _addAaveReserve(address(standIn), stockFeed, 7300, false);
        uint256 wrapperId = _addAaveReserve(address(wrapper), stockFeed, 7300, false);

        address impl = address(new StockMigrationModule(address(dataProvider)));
        module = StockMigrationModule(address(new UUPSProxy(impl, abi.encodeWithSelector(StockMigrationModule.initialize.selector, address(roleRegistry)))));
        _enableModule(address(module));

        vm.startPrank(owner);
        gw.setReserveId(address(standIn), standInId);
        gw.setReserveId(address(wrapper), wrapperId);
        gw.setDriver(address(module), true);
        roleRegistry.grantRole(module.ETHER_FI_WALLET_ROLE(), keeper);
        roleRegistry.grantRole(roleRegistry.ADMIN_TIMELOCK_ROLE(), admin);
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

    /// A supplied stand-in becomes supplied wrapper with the health factor unchanged and nothing left loose.
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

    /// Loose stand-in is swapped and the wrapper is supplied to the gateway.
    function test_migrate_looseBalance_resuppliesWrapper() public {
        deal(address(standIn), address(safe), LOOSE);

        vm.prank(keeper);
        module.migrate(address(safe), address(standIn));

        assertEq(standIn.balanceOf(address(safe)), 0);
        assertEq(standIn.balanceOf(address(module)), LOOSE);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(wrapper)), LOOSE, 1, "wrapper not resupplied");
        assertEq(wrapper.balanceOf(address(module)), SEED - LOOSE);
    }

    /// Supplied and loose stand-in are swapped in one call.
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

    /// A matured lend opt-out is executed first, so the whole position is swapped loose and nothing is re-supplied.
    function test_migrate_optedOutSafe_unwindsThenSwapsLoose() public {
        _supplyToGateway(address(safe), address(standIn), SUPPLIED);
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(false))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.toggleLend(address(safe), false, owner1, abi.encodePacked(r, s, v));
        (,, uint64 modeDelay) = cashModule.getDelays();
        vm.warp(block.timestamp + modeDelay + 1);
        assertTrue(cashModule.isLendOptedOut(address(safe)));

        vm.prank(keeper);
        (uint256 supplied, uint256 loose) = module.migrate(address(safe), address(standIn));

        assertEq(supplied, 0);
        assertApproxEqAbs(loose, SUPPLIED, 1);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(standIn)), 0, 1, "stand-in still supplied");
        assertEq(gw.suppliedOf(address(safe), address(wrapper)), 0, "wrapper supplied for an opted-out safe");
        assertApproxEqAbs(wrapper.balanceOf(address(safe)), SUPPLIED, 1, "wrapper not loose in the safe");
        assertEq(standIn.balanceOf(address(safe)), 0);
    }

    /// A borrow taken during the opt-out delay blocks the unwind, so only the loose balance swaps and the supplied leg waits.
    function test_migrate_optedOutSafeWithDebt_swapsLooseAndDefersSupplied() public {
        _supplyToGateway(address(safe), address(standIn), SUPPLIED);
        deal(address(standIn), address(safe), LOOSE);
        _requestLendOptOut();
        _borrowOnGateway(address(safe), address(usdc), DEBT, recipient);
        (,, uint64 modeDelay) = cashModule.getDelays();
        vm.warp(block.timestamp + modeDelay + 1);
        assertTrue(cashModule.isLendOptedOut(address(safe)));

        vm.prank(keeper);
        vm.expectEmit(true, true, false, false, address(module));
        emit StockMigrationModule.SuppliedDeferred(address(safe), address(standIn), SUPPLIED, "");
        (uint256 supplied, uint256 loose) = module.migrate(address(safe), address(standIn));

        assertEq(supplied, 0);
        assertEq(loose, LOOSE);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(standIn)), SUPPLIED, 1, "supplied leg must wait for the repayment");
        assertEq(wrapper.balanceOf(address(safe)), LOOSE, "loose leg not swapped");
        assertEq(standIn.balanceOf(address(safe)), 0);
        assertGe(gw.debtOf(address(safe), address(usdc)), DEBT, "debt must be untouched");
    }

    /// With nothing loose, a blocked opt-out is reported as such rather than as nothing to migrate.
    function test_migrate_optedOutSafeWithDebt_revertsOptOutBlocked() public {
        _supplyToGateway(address(safe), address(standIn), SUPPLIED);
        _requestLendOptOut();
        _borrowOnGateway(address(safe), address(usdc), DEBT, recipient);
        (,, uint64 modeDelay) = cashModule.getDelays();
        vm.warp(block.timestamp + modeDelay + 1);

        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.OptOutBlocked.selector);
        module.migrate(address(safe), address(standIn));
    }

    /// @dev Signs the safe's lend opt-out request; it matures after the mode delay
    function _requestLendOptOut() internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(false))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.toggleLend(address(safe), false, owner1, abi.encodePacked(r, s, v));
    }

    /// A legacy safe has no gateway position, so the wrapper stays loose.
    function test_migrate_legacySafe_wrapperStaysLoose() public {
        _forceLegacyEngine(address(safe));
        deal(address(standIn), address(safe), LOOSE);

        vm.prank(keeper);
        module.migrate(address(safe), address(standIn));

        assertEq(wrapper.balanceOf(address(safe)), LOOSE, "wrapper must stay loose for a legacy safe");
        assertEq(standIn.balanceOf(address(module)), LOOSE);
    }

    /// A legacy safe with stand-in-backed debt migrates once the wrapper is DebtManager collateral; the debt is untouched.
    function test_migrate_legacySafeWithDebt_passesWhenWrapperIsLegacyCollateral() public {
        _forceLegacyEngine(address(safe));
        _listLegacyCollateral(address(standIn));
        _listLegacyCollateral(address(wrapper));
        uint256 debt = _borrowLegacyAgainst(LOOSE);

        vm.prank(keeper);
        module.migrate(address(safe), address(standIn));

        assertEq(wrapper.balanceOf(address(safe)), LOOSE, "wrapper must stay loose for a legacy safe");
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), debt, "debt must be untouched");
    }

    /// Without the wrapper listed as legacy collateral the swap would strand the debt, so the hook's health check reverts.
    function test_migrate_legacySafeWithDebt_reverts_whenWrapperNotLegacyCollateral() public {
        _forceLegacyEngine(address(safe));
        _listLegacyCollateral(address(standIn));
        _borrowLegacyAgainst(LOOSE);

        vm.prank(keeper);
        vm.expectRevert(DebtManagerStorageContract.AccountUnhealthy.selector);
        module.migrate(address(safe), address(standIn));
    }

    /// @dev Lists `token` on the legacy DebtManager at the stock feed's fixed price
    function _listLegacyCollateral(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: stockFeed,
            priceFunctionCalldata: abi.encodeWithSignature("latestAnswer()"),
            isChainlinkType: false,
            oraclePriceDecimals: 8,
            maxStaleness: type(uint24).max,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        vm.startPrank(owner);
        priceProvider.setTokenConfig(tokens, configs);
        debtManager.supportCollateralToken(token, IDebtManager.CollateralTokenConfig({ ltv: ltv, liquidationThreshold: liquidationThreshold, liquidationBonus: liquidationBonus }));
        vm.stopPrank();
    }

    /// @dev Gives the legacy safe `amount` of stand-in as its only collateral and borrows up to the limit against it
    function _borrowLegacyAgainst(uint256 amount) internal returns (uint256) {
        deal(address(standIn), address(safe), amount);
        uint256 debt = debtManager.getMaxBorrowAmount(address(safe), true);
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), debt);
        return debt;
    }

    /// Stand-in under a pending withdrawal is left for the keeper to handle by hand.
    function test_migrate_reverts_whenPendingWithdrawal() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.mockCall(address(cashModule), abi.encodeWithSelector(ICashModule.getPendingWithdrawalAmount.selector, address(safe), address(standIn)), abi.encode(uint256(1)));

        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.PendingWithdrawal.selector);
        module.migrate(address(safe), address(standIn));
    }

    /// A safe holding no stand-in is refused.
    function test_migrate_reverts_whenNothingToMigrate() public {
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.NothingToMigrate.selector);
        module.migrate(address(safe), address(standIn));
    }

    /// The module must hold enough wrapper seed to pay the full swap.
    function test_migrate_reverts_whenSeedShort() public {
        deal(address(standIn), address(safe), SEED + 1);
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.InsufficientSeed.selector);
        module.migrate(address(safe), address(standIn));
    }

    /// A token without a swap pair is refused.
    function test_migrate_reverts_whenPairNotSet() public {
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.PairNotSet.selector);
        module.migrate(address(safe), address(raw));
    }

    /// Only the keeper role runs swaps.
    function test_migrate_reverts_whenNotKeeper() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.prank(admin);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.migrate(address(safe), address(standIn));
    }

    /// Pause blocks swaps.
    function test_migrate_reverts_whenPaused() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.prank(owner);
        module.pause();
        vm.prank(keeper);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        module.migrate(address(safe), address(standIn));
    }

    /// The try/catch target is callable only by the module itself.
    function test_migrateSelf_reverts_whenNotSelf() public {
        vm.prank(keeper);
        vm.expectRevert(StockMigrationModule.OnlySelf.selector);
        module.migrateSelf(address(safe), address(standIn));
    }

    /// A batch logs each failing safe and keeps going; the return value counts the successes.
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

    /// Swap pairs are timelocked.
    function test_setSwapPairs_reverts_whenNotAdmin() public {
        vm.prank(keeper);
        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
        module.setSwapPairs(_addr1(address(standIn)), _addr1(address(wrapper)));
    }

    /// The timelocked sweep moves collected stand-in (whole balance on zero) and unused seed to the treasury.
    function test_sweep_adminOnly_movesCollectedAndSeed() public {
        deal(address(standIn), address(safe), LOOSE);
        vm.prank(keeper);
        module.migrate(address(safe), address(standIn));

        vm.prank(keeper);
        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
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
