// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerStorageContract } from "../../src/debt-manager/DebtManagerStorageContract.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { BinSponsor, Cashback, ICashModule, Mode } from "../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../src/libraries/CashVerificationLib.sol";
import { IGateway } from "../../src/interfaces/IGateway.sol";
import { Gateway } from "../../src/modules/gateway/Gateway.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
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
    using MessageHashUtils for bytes32;

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
        // Migration reads the gateway from CashModule (single source of truth); authorize the migration runner
        cashModule.setGateway(address(gw));
        roleRegistry.grantRole(DEBT_MANAGER_ADMIN_ROLE, migrator);
        vm.stopPrank();

        _enableModule(address(gw));
        _activateAavePositionManager(address(gw));

        // The safes in this suite model the pre-gateway population: route them to the legacy engine so
        // migration is the thing that flips them (new safes onboard onto the gateway by default).
        _forceLegacyEngine(address(safe));
    }

    /// @dev Empty on purpose: skips the base mock-gateway wiring so this suite's one-time setGateway(gw) above is
    ///      the first and only set. Without this, that call would revert GatewayAlreadySet.
    function _wireDefaultGateway() internal override { }

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

        // Legacy debt closed and Safe flagged migrated; both latches flip in the same tx
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "legacy debt cleared");
        assertTrue(dm.hasMigratedToAave(address(safe)), "marked migrated");
        assertTrue(cashModule.isAaveGatewaySafe(address(safe)), "CashModule routing flag flipped");
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

    function test_migrateToAave_noDebt_suppliesCollateralAndMarksMigrated() public {
        deal(address(weETH), address(safe), 10 ether); // collateral but no debt
        assertFalse(dm.hasMigratedToAave(address(safe)));

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        assertTrue(dm.hasMigratedToAave(address(safe)), "marked migrated");
        // A debt-free migration still moves the collateral to Aave, so credit borrowing works post-migration
        // (marking migrated while leaving collateral idle in the Safe would break gateway-based credit spends).
        assertEq(weETH.balanceOf(address(safe)), 0, "collateral moved out of the Safe");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 10 ether, 2, "collateral supplied to Aave");
        assertGt(gw.getAccountData(address(safe)).availableBorrowsUsd, 0, "has Aave borrowing power");
    }

    /// @dev A lend-disabled safe opted out of Aave, so migration must not force its collateral in: it just
    ///      gets marked migrated (freezing legacy borrow/repay) with its balance left idle in the safe.
    function test_migrateToAave_lendDisabledSafe_marksMigratedWithoutSupplying() public {
        deal(address(weETH), address(safe), 10 ether);
        _disableLendForSafe();
        assertFalse(cashModule.isLendEnabled(address(safe)), "lend disabled");

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        assertTrue(dm.hasMigratedToAave(address(safe)), "marked migrated");
        assertEq(weETH.balanceOf(address(safe)), 10 ether, "collateral stayed in the safe");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "nothing supplied to Aave");
    }

    /// @dev A lend-disabled safe should be debt-free (disabling requires zero borrows), but it can still borrow
    ///      on DebtManager directly afterward. Migration must reject that case rather than revert opaquely.
    function test_migrateToAave_lendDisabledSafe_withDebt_reverts() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        _disableLendForSafe();

        // Borrow on DebtManager while lend is disabled (borrow only checks whenNotMigrated, not lend)
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        vm.expectRevert(DebtManagerStorageContract.LendDisabledSafeHasDebt.selector);
        dm.migrateToAave(address(safe));
    }

    /// @dev Pending withdrawals reserve loose funds; migration must not sweep them into Aave. The queued
    ///      withdrawal is a plain transfer of the Safe's balance, so supplying it would brick processWithdrawal.
    function test_migrateToAave_leavesPendingWithdrawalLoose() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 8;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        // Queue a withdrawal of 2 weETH, then migrate before the delay elapses
        uint256 withdrawAmt = 2 ether;
        address[] memory tokens = new address[](1);
        tokens[0] = address(weETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawAmt;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        // Reserved amount stayed loose; only the rest was supplied
        assertEq(weETH.balanceOf(address(safe)), withdrawAmt, "reserved amount left loose in the safe");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 10 ether - withdrawAmt, 3, "unreserved collateral supplied");

        // The queued withdrawal still processes normally after the delay
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(address(safe));
        assertEq(weETH.balanceOf(withdrawRecipient), withdrawAmt, "withdrawal paid out post-migration");
        assertEq(weETH.balanceOf(address(safe)), 0, "safe holds nothing loose afterwards");
    }

    function test_markAaveGatewaySafe_onlyDebtManager() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(ICashModule.OnlyDebtManager.selector);
        cashModule.markAaveGatewaySafe(address(safe));
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

    /// @dev After migration, a credit-mode spend must borrow from Aave (via the gateway), not the frozen
    ///      DebtManager. Regression for: migrated safe passes CashLens (gateway-based) but reverts on spend
    ///      with AlreadyMigratedToAave because _spendCredit still called DebtManager.borrow.
    function test_migratedSafe_creditSpendBorrowsFromAave() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Legacy position with collateral + modest debt, then migrate to Aave (leaves borrow headroom there)
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));
        assertTrue(dm.hasMigratedToAave(address(safe)), "safe migrated");

        // Enter Credit mode (the gateway is wired to the CashModule in setUp)
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Credit), "in credit mode");

        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);
        uint256 aaveDebtBefore = gw.debtOf(address(safe), address(usdc));

        uint256 spendUsd = 100e6; // $100, within the daily limit
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = spendUsd;
        Cashback[] memory cashbacks;

        // Must NOT revert with AlreadyMigratedToAave
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("credit-after-migration"), BinSponsor.Reap, tokens, amounts, cashbacks);

        // Borrowed from Aave and forwarded to the settlement dispatcher; DebtManager debt stays zero
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)) - aaveDebtBefore, spendUsd, 1e6, "borrowed from Aave");
        assertApproxEqAbs(usdc.balanceOf(dispatcher) - dispatcherBefore, spendUsd, 2, "dispatcher funded from Aave borrow");
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "no new DebtManager debt");
    }

    /// @dev After migration, the wallet's standard repay must reduce the Aave debt via the gateway, not revert
    ///      on the frozen DebtManager.repay. Regression for the "migrated safes cannot repay" finding.
    function test_migratedSafe_repayReducesAaveDebt() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Migrate a position carrying debt, so there is Aave debt to repay
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));
        uint256 aaveDebtBefore = gw.debtOf(address(safe), address(usdc));
        assertGt(aaveDebtBefore, 0, "has Aave debt");

        // Fund the safe to repay (the gateway is wired to the CashModule in setUp)
        deal(address(usdc), address(safe), 500e6);
        uint256 repayUsd = 200e6;

        // Must NOT revert with AlreadyMigratedToAave, and must surface a gateway-repay event (indexed topics
        // checked; the exact repaid amount is left to the assertions below)
        vm.expectEmit(true, true, false, false);
        emit CashEventEmitter.Repay(address(safe), address(usdc), 0, 0);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), repayUsd);

        // Aave debt reduced by ~the repay amount; the DebtManager was never touched
        assertApproxEqAbs(aaveDebtBefore - gw.debtOf(address(safe), address(usdc)), repayUsd, 1e6, "Aave debt reduced");
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "DebtManager debt still zero");
    }

    /// A repay that covers the debt clears it fully: the sentinel path repays the live Aave debt (principal plus
    /// interest accrued since the quote) so no dust survives, and refunds the unused balance to the safe.
    function test_migratedSafe_fullRepay_clearsAaveDebtWithoutDust() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Migrate a position carrying debt, then let interest accrue so the live debt exceeds the migrated principal.
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        vm.warp(block.timestamp + 30 days);
        uint256 liveDebt = gw.debtOf(address(safe), address(usdc));
        assertGt(liveDebt, borrowAmt, "interest accrued on the Aave debt");

        // Repay a USD amount above the live debt so the sentinel path fires; fund the safe with more than that.
        uint256 liveDebtUsd = debtManager.convertCollateralTokenToUsd(address(usdc), liveDebt);
        deal(address(usdc), address(safe), liveDebtUsd * 2);
        uint256 safeBalBefore = usdc.balanceOf(address(safe));

        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), liveDebtUsd + 1e6);

        // Full repay leaves zero dust, and only the live debt was pulled from the safe (the excess is refunded).
        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "Aave debt fully cleared, no dust");
        assertApproxEqAbs(safeBalBefore - usdc.balanceOf(address(safe)), liveDebt, 2, "only the live debt was pulled");
    }

    // ----------------------------------------------------------------- migration boundary
    // A card auth is decided off-chain (CashLens.canSpend) seconds before the spend lands on-chain. If the
    // migration sweep moves the safe in between, the auth was checked against the legacy engine but the
    // spend executes on the gateway. These tests pin that hand-off.

    /// A credit auth approved pre-migration (legacy check) lands post-migration as an Aave borrow.
    function test_migrationBoundary_creditAuth_landsOnAave() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        deal(address(usdc), address(debtManager), 1000e6); // legacy credit check requires DebtManager liquidity

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        (bool ok, string memory reason) = cashLens.canSpend(address(safe), keccak256("boundary-credit"), tokens, amounts);
        assertTrue(ok, reason);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("boundary-credit"), BinSponsor.Reap, tokens, amounts, cashbacks);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 100e6, 1e6, "borrowed on Aave, not the DebtManager");
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "no legacy debt");
    }

    /// A debit auth approved pre-migration against the loose balance sources from the Aave-supplied
    /// position post-migration (migration moved the funds there).
    function test_migrationBoundary_debitAuth_sourcesFromAave() public {
        deal(address(usdc), address(safe), 100e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;

        (bool ok, string memory reason) = cashLens.canSpend(address(safe), keccak256("boundary-debit"), tokens, amounts);
        assertTrue(ok, reason);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));
        assertEq(usdc.balanceOf(address(safe)), 0, "migration supplied the loose balance");

        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);

        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("boundary-debit"), BinSponsor.Reap, tokens, amounts, cashbacks);

        assertEq(usdc.balanceOf(dispatcher), dispatcherBefore + 50e6, "debit sourced from the supplied position");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 50e6, 2, "supplied position reduced");
    }

    /// Gateway-credit declined-side parity: a check declined for borrowing power implies the Aave borrow
    /// reverts (the mock gateway cannot model this; the real Aave instance enforces it).
    function test_migrationBoundary_gatewayCreditDeclined_revertsOnSpend() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 1 ether);

        vm.prank(migrator);
        dm.migrateToAave(address(safe));

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 tooMuch = gw.getAccountData(address(safe)).availableBorrowsUsd + 100e6;
        assertLt(tooMuch, dailyLimitInUsd, "test premise: declined by borrow power, not the limit");

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = tooMuch;

        (bool ok, string memory reason) = cashLens.canSpend(address(safe), keccak256("boundary-declined"), tokens, amounts);
        assertFalse(ok);
        assertEq(reason, "Insufficient borrowing power");

        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        vm.expectRevert(); // Aave enforces the borrowing power on the borrow itself
        cashModule.spend(address(safe), keccak256("boundary-declined"), BinSponsor.Reap, tokens, amounts, cashbacks);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Opts the safe out of lend (owner-signed toggleLend(false)), executing the pending request if the
    ///      mode delay is nonzero so the safe ends up fully lend-disabled.
    function _disableLendForSafe() internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(false))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.toggleLend(address(safe), false, owner1, abi.encodePacked(r, s, v));

        if (cashModule.isLendEnabled(address(safe))) {
            (,, uint64 modeDelay) = cashModule.getDelays();
            vm.warp(block.timestamp + modeDelay + 1);
            cashModule.processLendDisable(address(safe));
        }
    }

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
