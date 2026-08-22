// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Vm } from "forge-std/Vm.sol";

import { DebtManagerCore } from "../../../../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerStorageContract } from "../../../../../src/debt-manager/DebtManagerStorageContract.sol";
import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title DebtManagerMigrationTest
 * @notice Fork tests for DebtManager.migrateToLendGateway: a legacy Safe position (weETH collateral + USDC debt on
 *         DebtManager) migrates atomically to a REAL Aave v4 instance (deployed in-test on an Optimism fork)
 *         via the gateway — no flash loan. Aave's weETH LTV is set below DebtManager's so the LTV-fit path
 *         is exercised.
 * @dev Run with: FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/DebtManagerMigration.t.sol
 */
contract DebtManagerMigrationTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    DebtManagerCore internal dm;
    address internal migrator = makeAddr("migrationRunner");

    uint16 internal constant AAVE_WEETH_LTV = 3000; // below DebtManager's 50%, to exercise the LTV-fit guard

    function setUp() public override {
        super.setUp();
        dm = DebtManagerCore(address(debtManager));

        vm.startPrank(owner);
        gw.setDriver(address(dm), true); // DebtManager drives the gateway during migration
        roleRegistry.grantRole(dm.ETHER_FI_WALLET_ROLE(), migrator); // authorize the migration runner
        vm.stopPrank();

        // The safes in this suite model the pre-gateway population: route them to the legacy engine so
        // migration is the thing that flips them (new safes onboard onto the gateway by default).
        _forceLegacyEngine(address(safe));
    }

    /// @dev Aave's weETH LTV sits below DebtManager's 50%, so migration exercises the LTV-fit path.
    function _weethCollateralFactorBps() internal pure override returns (uint16) {
        return AAVE_WEETH_LTV;
    }

    /// @dev This suite seeds Aave liquidity per-test; a revert case relies on the reserve starting empty.
    function _seedInitialLiquidity() internal override { }

    // ----------------------------------------------------------------- happy path

    /// @dev The happy path: legacy debt clears, collateral and debt re-home to Aave atomically, nothing strands.
    function test_migrateToLendGateway_atomic_noFlashLoan() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Legacy position: 10 weETH collateral, borrow a modest fraction that fits Aave's 30% LTV
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4; // ~12.5% of collateral value
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdc)), borrowAmt, 1, "legacy debt created");

        uint256 dmUsdcBefore = usdc.balanceOf(address(debtManager));

        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));

        // Legacy debt closed and Safe flagged migrated; both latches flip in the same tx
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "legacy debt cleared");
        assertTrue(dm.hasMigratedToLendGateway(address(safe)), "marked migrated");
        assertTrue(cashModule.usesLendGateway(address(safe)), "CashModule routing flag flipped");
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

    /// @dev Invariant I17 (spec 7.3.5, "Migration exclusion"): the cashback fold consumes exactly six events
    ///      (LendBorrowed, Spend, Repay, RepayDebtManager, Liquidated, LiquidationCall) and migration must
    ///      reach a real, successful outcome without emitting any fold input the Cash/DebtManager stack could
    ///      plausibly produce. `_gateway.borrow(...)` bypasses `CashLendLib.borrow()` (the only emitter of
    ///      `LendBorrowed`), and `_clearLegacyDebt` emits no `Repay`/`RepayDebtManager`/`Spend`/`Liquidated`.
    ///      Asserted on recorded log selectors, not `expectEmit` absence, so this test also catches an entirely
    ///      new emission point a refactor might add. Guards against, e.g., a refactor that routes the Aave
    ///      re-borrow through `CashLendLib.borrow()`, emits `Repay` or `RepayDebtManager` while clearing the
    ///      legacy debt (`RepayDebtManager` — CashEventEmitter.sol:87 — is the natural event `_clearLegacyDebt`
    ///      would gain), or folds the debt clear into a `Spend`-shaped or `Liquidated`-shaped emission — any of
    ///      which would let a migrated account silently earn borrow cashback on debt that predates the gateway.
    ///      `LiquidationCall` (Aave's own Spoke event) is excluded: migration never calls Aave's liquidation
    ///      path, so there is no code path in this function that could ever reach it.
    function test_migrateToLendGateway_emitsNeitherLendBorrowedNorRepay() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Real legacy position carrying debt, so both suspect paths actually run: the legacy debt is cleared
        // AND the gateway is made to re-borrow the same amount on Aave.
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.recordLogs();
        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));

        // Prove this is a real, successful migration, not a revert that trivially emitted nothing.
        assertTrue(dm.hasMigratedToLendGateway(address(safe)), "migration actually succeeded");
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "legacy debt actually cleared");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowAmt, 1e6, "debt actually re-homed on Aave");

        // Every fold input the emitter stack can produce (spec 7.3.5's six events, minus Aave-native
        // LiquidationCall, which migration structurally cannot reach). Selectors are computed from the live
        // event declarations via `.selector`, never hand-copied, so a signature change can't silently desync
        // the guard from what the fold — and the indexer — actually decode.
        bytes32[5] memory forbidden = [
            CashEventEmitter.LendBorrowed.selector,
            CashEventEmitter.Repay.selector,
            CashEventEmitter.RepayDebtManager.selector,
            CashEventEmitter.Spend.selector,
            DebtManagerStorageContract.Liquidated.selector
        ];

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0, "sanity: a real migration must emit something (e.g. MigratedToLendGateway)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue; // anonymous log, cannot match a named event's selector
            for (uint256 j = 0; j < forbidden.length; j++) {
                assertTrue(logs[i].topics[0] != forbidden[j], "migration emitted a cashback-fold input event");
            }
        }
    }

    // ----------------------------------------------------------------- reverts

    /// @dev A position that fits DebtManager's LTV but not Aave's reverts with the typed LTV-fit error.
    function test_migrateToLendGateway_revertsWhenExceedsAaveLtv() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Borrow ~90% of DebtManager's max: fits DebtManager's 50% LTV, exceeds Aave's 30%
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = (dm.getMaxBorrowAmount(address(safe), true) * 9) / 10;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        vm.expectRevert(DebtManagerStorageContract.PositionExceedsLendGatewayLtv.selector);
        dm.migrateToLendGateway(address(safe));
    }

    /// @dev An Aave reserve that cannot fund the re-borrow reverts with the typed liquidity error.
    function test_migrateToLendGateway_revertsWhenInsufficientLendGatewayLiquidity() public {
        // No Aave liquidity seeded → the reserve cannot fund the borrow
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        vm.expectRevert(abi.encodeWithSelector(DebtManagerStorageContract.InsufficientLendGatewayLiquidity.selector, address(usdc)));
        dm.migrateToLendGateway(address(safe));
    }

    /// @dev An Aave reserve that cannot take the collateral supply (here: at its addCap) reverts with the
    ///      typed error instead of Aave's raw AddCapExceeded, so a batch runner can route the Safe.
    function test_migrateToLendGateway_revertsWhenReserveCannotAcceptSupply() public {
        deal(address(weETH), address(safe), 10 ether);
        _setAaveSpokeCaps(weethReserveId, 1, type(uint40).max);

        vm.prank(migrator);
        vm.expectRevert(abi.encodeWithSelector(DebtManagerStorageContract.LendGatewayCannotAcceptSupply.selector, address(weETH)));
        dm.migrateToLendGateway(address(safe));
    }

    /// @dev A debt-free safe still migrates: its collateral moves to Aave so post-migration credit spends work.
    function test_migrateToLendGateway_noDebt_suppliesCollateralAndMarksMigrated() public {
        deal(address(weETH), address(safe), 10 ether); // collateral but no debt
        assertFalse(dm.hasMigratedToLendGateway(address(safe)));

        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));

        assertTrue(dm.hasMigratedToLendGateway(address(safe)), "marked migrated");
        // A debt-free migration still moves the collateral to Aave, so credit borrowing works post-migration
        // (marking migrated while leaving collateral idle in the Safe would break gateway-based credit spends).
        assertEq(weETH.balanceOf(address(safe)), 0, "collateral moved out of the Safe");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 10 ether, 2, "collateral supplied to Aave");
        assertGt(gw.getAccountData(address(safe)).availableBorrowsUsd, 0, "has Aave borrowing power");
    }

    /// @dev A lend-disabled safe opted out of Aave, so migration must not force its collateral in: it just
    ///      gets marked migrated (freezing legacy borrow/repay) with its balance left idle in the safe.
    function test_migrateToLendGateway_optedOutSafe_marksMigratedWithoutSupplying() public {
        deal(address(weETH), address(safe), 10 ether);
        _optOutOfLend();
        assertTrue(cashModule.isLendOptedOut(address(safe)), "safe opted out of lend");

        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));

        assertTrue(dm.hasMigratedToLendGateway(address(safe)), "marked migrated");
        assertEq(weETH.balanceOf(address(safe)), 10 ether, "collateral stayed in the safe");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "nothing supplied to Aave");
    }

    /// @dev A lend-disabled safe should be debt-free (disabling requires zero borrows), but it can still borrow
    ///      on DebtManager directly afterward. Migration must reject that case rather than revert opaquely.
    function test_migrateToLendGateway_optedOutSafe_withDebt_reverts() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        _optOutOfLend();

        // Borrow on DebtManager while lend is disabled (borrow only checks whenNotMigrated, not lend)
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        vm.expectRevert(DebtManagerStorageContract.LendOptedOutSafeHasDebt.selector);
        dm.migrateToLendGateway(address(safe));
    }

    /// @dev Pending withdrawals reserve loose funds; migration must not sweep them into Aave. The queued
    ///      withdrawal is a plain transfer of the Safe's balance, so supplying it would brick processWithdrawal.
    function test_migrateToLendGateway_leavesPendingWithdrawalLoose() public {
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
        dm.migrateToLendGateway(address(safe));

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

    /// @dev Only the DebtManager may flip the CashModule's engine routing flag.
    function test_markUsesLendGateway_onlyDebtManager() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(ICashModule.OnlyDebtManager.selector);
        cashModule.markUsesLendGateway(address(safe));
    }

    /// @dev Migration is gated to the EtherFi wallet role; anyone else is rejected.
    function test_migrateToLendGateway_onlyEtherFiWallet() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(makeAddr("notMigrator"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        dm.migrateToLendGateway(address(safe));
    }

    /// @dev After migration the legacy engine is frozen: DebtManager borrow and repay both reject the safe.
    function test_migratedSafe_cannotBorrowOrRepayOnDebtManager() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));
        assertTrue(dm.hasMigratedToLendGateway(address(safe)));

        // Legacy borrow is frozen for a migrated Safe
        vm.prank(address(safe));
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        debtManager.borrow(BinSponsor.Reap, address(usdc), 1e6);

        // Legacy repay is frozen for a migrated Safe
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        debtManager.repay(address(safe), address(usdc), 1e6);
    }

    /// @dev A safe onboarded straight onto the gateway never migrates, so the migration latch alone would
    ///      let it open legacy debt the Cash flows no longer look at. The engine flag must block it — and
    ///      keep blocking it after an opt-out, which leaves the safe with no borrow engine at all.
    function test_gatewayOnboardedSafe_cannotUseDebtManager() public {
        _forceGatewayEngine(address(safe));
        assertFalse(dm.hasMigratedToLendGateway(address(safe)), "gateway-onboarded safe never migrated");

        vm.prank(address(safe));
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        debtManager.borrow(BinSponsor.Reap, address(usdc), 1e6);

        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        debtManager.repay(address(safe), address(usdc), 1e6);

        address[] memory pref = new address[](1);
        pref[0] = address(weETH);
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        debtManager.liquidate(address(safe), address(usdc), pref);

        // Migration is meaningless for a safe already on the gateway; it must not sweep its loose funds
        vm.prank(migrator);
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        dm.migrateToLendGateway(address(safe));

        // Opting out keeps the raw engine flag set, so the legacy engine stays closed
        _optOutOfLend();
        assertTrue(cashModule.usesLendGateway(address(safe)), "opt-out keeps the engine flag");
        vm.prank(address(safe));
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        debtManager.borrow(BinSponsor.Reap, address(usdc), 1e6);
    }

    /// @dev Migration is exactly-once: a repeat call must revert rather than silently sweep new loose
    ///      balances into Aave and re-emit the migration event. Batch runners skip migrated safes.
    function test_migrateToLendGateway_secondCall_reverts() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 10 ether);
        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));

        // A balance arriving after migration must not be silently supplied by a re-run
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(migrator);
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        dm.migrateToLendGateway(address(safe));
        assertEq(weETH.balanceOf(address(safe)), 1 ether, "post-migration balance stayed loose");
    }

    /// @dev After migration, a credit-mode spend must borrow from Aave (via the gateway), not the frozen
    ///      DebtManager. Regression for: migrated safe passes CashLens (gateway-based) but reverts on spend
    ///      with AlreadyMigratedToLendGateway because _spendCredit still called DebtManager.borrow.
    function test_migratedSafe_creditSpendBorrowsFromAave() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        // Legacy position with collateral + modest debt, then migrate to Aave (leaves borrow headroom there)
        deal(address(weETH), address(safe), 10 ether);
        uint256 borrowAmt = dm.getMaxBorrowAmount(address(safe), true) / 4;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));
        assertTrue(dm.hasMigratedToLendGateway(address(safe)), "safe migrated");

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

        // Must NOT revert with AlreadyMigratedToLendGateway
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
        dm.migrateToLendGateway(address(safe));
        uint256 aaveDebtBefore = gw.debtOf(address(safe), address(usdc));
        assertGt(aaveDebtBefore, 0, "has Aave debt");

        // Fund the safe to repay (the gateway is wired to the CashModule in setUp)
        deal(address(usdc), address(safe), 500e6);
        uint256 repayUsd = 200e6;

        // Must NOT revert with AlreadyMigratedToLendGateway, and must surface a gateway-repay event (indexed topics
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
        dm.migrateToLendGateway(address(safe));

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
        dm.migrateToLendGateway(address(safe));

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
        dm.migrateToLendGateway(address(safe));
        assertEq(usdc.balanceOf(address(safe)), 0, "migration supplied the loose balance");

        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);

        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("boundary-debit"), BinSponsor.Reap, tokens, amounts, cashbacks);

        assertEq(usdc.balanceOf(dispatcher), dispatcherBefore + 50e6, "debit sourced from the supplied position");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 50e6, 2, "supplied position reduced");
    }

    /// LendGateway-credit declined-side parity: a check declined for borrowing power implies the Aave borrow
    /// reverts (the mock gateway cannot model this; the real Aave instance enforces it).
    function test_migrationBoundary_gatewayCreditDeclined_revertsOnSpend() public {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        deal(address(weETH), address(safe), 1 ether);

        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));

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
    function _optOutOfLend() internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(false))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.toggleLend(address(safe), false, owner1, abi.encodePacked(r, s, v));

        if (!cashModule.isLendOptedOut(address(safe))) {
            (,, uint64 modeDelay) = cashModule.getDelays();
            vm.warp(block.timestamp + modeDelay + 1);
            cashModule.processLendOptOut(address(safe));
        }
    }
}
