// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { DebtManagerCore } from "../../../../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerStorageContract } from "../../../../../src/debt-manager/DebtManagerStorageContract.sol";
import { BinSponsor, Cashback, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title DebtManagerMigrationFuzzTest
 * @notice Conservation fuzz for migrateToLendGateway across position sizes, utilization, accrued interest,
 *         and pending withdrawals: the debt lands on Aave within the re-borrow pad (never forgiven, never
 *         padded past the buffer), the collateral is preserved exactly, the reservation stays loose, the
 *         safe arrives healthy and functional, and the migration is final.
 * @dev The deterministic DebtManagerMigration.t.sol pins the revert paths (LTV fit, liquidity); this file
 *      fuzzes the conserving happy path, so debt sizes are capped to always fit Aave's LTV.
 *      Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/DebtManagerMigrationFuzz.t.sol"
 */
contract DebtManagerMigrationFuzzTest is CashGatewayTestSetup {
    DebtManagerCore internal dm;
    address internal migrator = makeAddr("migrationRunner");

    // Mirrors DebtManagerCore.MIGRATION_REBORROW_BUFFER_BPS (private constant)
    uint256 internal constant REBORROW_PAD_BPS = 10;

    /// Authorizes the DebtManager as a gateway driver and the migration runner, seeds Aave liquidity,
    /// and routes the safe to the legacy engine so migration is the thing that flips it.
    function setUp() public override {
        super.setUp();
        dm = DebtManagerCore(address(debtManager));

        vm.startPrank(owner);
        gw.setDriver(address(dm), true);
        roleRegistry.grantRole(dm.ETHER_FI_WALLET_ROLE(), migrator);
        vm.stopPrank();

        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
        _forceLegacyEngine(address(safe));
    }

    /// Builds a fuzzed legacy position (collateral, debt, reservation, accrual), migrates it, and asserts
    /// the conservation properties: debt band, collateral, reservation, health, finality, and liveness.
    /// forge-config: lend.fuzz.runs = 64
    function testFuzz_migration_conservesPosition(uint256 collateralWeeth, uint256 debtBps, uint256 withdrawalBpsOfFreeCollateral, uint256 warpSecs) public {
        collateralWeeth = bound(collateralWeeth, 0.5 ether, 50 ether);
        debtBps = bound(debtBps, 0, 9500);
        // Capped just under the whole free amount, leaving room for the conversion rounding below
        withdrawalBpsOfFreeCollateral = bound(withdrawalBpsOfFreeCollateral, 0, 9900);
        warpSecs = bound(warpSecs, 0, 1 hours);

        // Legacy position: loose weETH collateral, optional DebtManager debt, optional reservation.
        // Aave's weETH LTV (80%) sits above DebtManager's, so every legacy-max-fitting debt migrates.
        deal(address(weETH), address(safe), collateralWeeth);
        uint256 borrowAmt = (dm.getMaxBorrowAmount(address(safe), true) * debtBps) / 10_000;
        if (borrowAmt > 0) {
            vm.prank(address(safe));
            debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);
        }
        // The request is health-checked, so the reservation has to fit the collateral the debt does not
        // need. Health requires borrowings <= collateral * LTV, so the removable collateral value is the
        // unused borrowing power grossed back up by the LTV. Taking a fraction of THAT keeps the dimension
        // meaningful at every debt level, where a fraction of the raw collateral would not.
        (, uint256 borrowingsUsd) = dm.borrowingOf(address(safe));
        uint256 maxBorrowUsd = dm.getMaxBorrowAmount(address(safe), true);
        uint256 freeUsd = maxBorrowUsd > borrowingsUsd ? Math.mulDiv(maxBorrowUsd - borrowingsUsd, dm.HUNDRED_PERCENT(), ltv) : 0;
        uint256 freeWeeth = dm.convertUsdToCollateralToken(address(weETH), freeUsd);
        uint256 pendingAmt = (freeWeeth * withdrawalBpsOfFreeCollateral) / 10_000;
        if (pendingAmt > 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(weETH);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = pendingAmt;
            _requestWithdrawal(tokens, amounts, withdrawRecipient);
        }
        vm.warp(block.timestamp + warpSecs); // legacy interest accrues, so the migrated size is off round numbers

        uint256 debtBefore = debtManager.borrowingOf(address(safe), address(usdc));

        vm.prank(migrator);
        dm.migrateToLendGateway(address(safe));

        // Debt band: nothing forgiven, nothing borrowed past the re-borrow pad
        uint256 aaveDebt = gw.debtOf(address(safe), address(usdc));
        assertGe(aaveDebt, debtBefore, "no debt forgiven by migration");
        assertLe(aaveDebt, Math.mulDiv(debtBefore, 10_000 + REBORROW_PAD_BPS, 10_000, Math.Rounding.Ceil), "re-borrow stays inside the pad");

        // Collateral conserved with no share-rounding loss at all, and the reservation left loose
        uint256 loose = weETH.balanceOf(address(safe));
        assertGe(gw.suppliedOf(address(safe), address(weETH)) + loose, collateralWeeth, "collateral preserved");
        assertGe(loose, pendingAmt, "the reservation stays loose for the pending withdrawal");

        // The safe arrives healthy, the legacy books are closed, and the move is final
        if (aaveDebt > 0) {
            assertGe(spoke.getUserAccountData(address(safe)).healthFactor, 1e18, "healthy on Aave");
        }
        assertEq(debtManager.borrowingOf(address(safe), address(usdc)), 0, "legacy debt cleared");
        assertTrue(dm.hasMigratedToLendGateway(address(safe)), "marked migrated");
        assertTrue(cashModule.usesLendGateway(address(safe)), "routing flag flipped");
        vm.prank(migrator);
        vm.expectRevert(DebtManagerStorageContract.SafeUsesLendGateway.selector);
        dm.migrateToLendGateway(address(safe));

        // Nothing stranded on the movers
        assertEq(weETH.balanceOf(address(gw)), 0, "no stranded weETH on the gateway");
        assertEq(usdc.balanceOf(address(gw)), 0, "no stranded USDC on the gateway");

        // Liveness: the migrated safe spends on the gateway (credit borrows against the moved collateral)
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 1e6;
        (bool ok, string memory reason) = cashLens.canSpend(address(safe), txId, spendTokens, spendAmounts);
        assertTrue(ok, reason);
        Cashback[] memory noCashback;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, noCashback);
        assertGe(gw.debtOf(address(safe), address(usdc)), aaveDebt + 1e6 - 1, "the spend borrowed on Aave");
    }
}
