// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { IPriceProvider } from "../../../../../src/interfaces/IPriceProvider.sol";
import { LendSourcingLib } from "../../../../../src/libraries/LendSourcingLib.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title RepaySourcingTest
 * @notice Fork tests for the gateway repay's sourcing: unreserved loose balance first, then the safe's
 *         Aave-supplied balance of the same token (withdrawn in the same tx, since Aave v4 has no
 *         repay-with-aTokens), and only as a last resort the withdrawal-reserved loose balance. A fully
 *         swept safe (all funds in Aave) must be able to repay, and a max-leveraged position unloops
 *         because the loose leg repays before the supplied leg is sized.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/RepaySourcing.t.sol
 */
contract RepaySourcingTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    /// @notice A gateway safe can repay Aave debt in token units while the Cash PriceProvider is unavailable.
    function test_repayLendTokenAmount_worksWhenPriceOracleReverts() public {
        uint256 borrowedUsdc = 300e6;
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowedUsdc);
        deal(address(usdc), address(safe), borrowedUsdc);

        address priceProvider = dataProvider.getPriceProvider();
        vm.mockCallRevert(priceProvider, abi.encodeWithSelector(IPriceProvider.price.selector, address(usdc)), "oracle unavailable");

        uint256 debt = gw.debtOf(address(safe), address(usdc));
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.RepayLendTokenAmount(address(safe), address(usdc), debt);
        vm.prank(etherFiWallet);
        cashModule.repayLendTokenAmount(address(safe), address(usdc), type(uint256).max);

        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "full debt repaid without an oracle read");
    }

    /// @notice Token repayment can source supplied funds while the Cash PriceProvider is unavailable.
    function test_repayLendTokenAmount_worksFromSuppliedWhenPriceProviderReverts() public {
        uint256 borrowedUsdc = 300e6;
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowedUsdc);
        _supplyToGateway(address(safe), address(usdc), borrowedUsdc);

        address priceProvider = dataProvider.getPriceProvider();
        vm.mockCallRevert(priceProvider, abi.encodeWithSelector(IPriceProvider.price.selector, address(usdc)), "oracle unavailable");

        vm.prank(etherFiWallet);
        cashModule.repayLendTokenAmount(address(safe), address(usdc), type(uint256).max);

        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "full debt repaid from supplied funds");
    }

    /// @notice Token-denominated repayment is unavailable to safes still using DebtManager.
    function test_repayLendTokenAmount_revertsForLegacySafe() public {
        _forceLegacyEngine(address(safe));

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyLendGatewaySafe.selector);
        cashModule.repayLendTokenAmount(address(safe), address(usdc), 1);
    }

    /// A fully swept safe (borrowed USDC auto-supplied, zero loose) repays its whole debt from the
    /// supplied balance; the sentinel path leaves no dust.
    function test_repay_fullDebtFromSuppliedWhenSwept() public {
        uint256 collateralWeeth = 5 ether;
        uint256 borrowedUsdc = 1000e6;
        _buildGatewayPosition(address(safe), address(weETH), collateralWeeth, address(usdc), borrowedUsdc);
        // The sweep supplied the borrowed USDC back into Aave: the safe holds aUSDC, nothing loose
        _supplyToGateway(address(safe), address(usdc), borrowedUsdc);
        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(usdc));
        uint256 debt = gw.debtOf(address(safe), address(usdc));
        assertEq(usdc.balanceOf(address(safe)), 0, "swept safe holds no loose USDC");

        uint256 debtUsd = debtManager.convertCollateralTokenToUsd(address(usdc), debt);
        vm.expectEmit(true, true, false, false);
        emit CashEventEmitter.Repay(address(safe), address(usdc), 0, 0);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), debtUsd + 1e6);

        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "debt fully cleared, no dust");
        assertApproxEqAbs(suppliedBefore - gw.suppliedOf(address(safe), address(usdc)), debt, 2, "repay withdrew only the debt from the supplied pot");
    }

    /// An over-repay is capped at the open debt and the event reports the capped USD value, not the
    /// requested one.
    function test_repay_overRepay_emitsCappedUsd() public {
        uint256 borrowedUsdc = 300e6;
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowedUsdc);
        deal(address(usdc), address(safe), 1000e6);

        uint256 debt = gw.debtOf(address(safe), address(usdc));
        uint256 debtUsd = debtManager.convertCollateralTokenToUsd(address(usdc), debt);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Repay(address(safe), address(usdc), debt, debtUsd);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), debtUsd + 100e6);
    }

    /// A partial repay consumes the loose balance before touching the supplied pot.
    function test_repay_sourcesLooseBeforeSupplied() public {
        uint256 borrowedUsdc = 400e6;
        uint256 suppliedUsdc = 1000e6;
        uint256 looseUsdc = 250e6;
        uint256 repayAmt = 300e6; // covered by all the loose plus (repayAmt - looseUsdc) from the supplied pot
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowedUsdc);
        _supplyToGateway(address(safe), address(usdc), suppliedUsdc);
        deal(address(usdc), address(safe), looseUsdc);
        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        uint256 repayUsd = debtManager.convertCollateralTokenToUsd(address(usdc), repayAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), repayUsd);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowedUsdc - repayAmt, 3, "debt reduced by the repay");
        assertApproxEqAbs(usdc.balanceOf(address(safe)), 0, 3, "loose consumed first");
        assertApproxEqAbs(suppliedBefore - gw.suppliedOf(address(safe), address(usdc)), repayAmt - looseUsdc, 3, "only the shortfall left the supplied pot");
    }

    /// Audit L-08: repayWithdrawable credited the repay's freed headroom on top of the CLAMPED raw
    /// headroom, over-crediting by the deficit while the position sits under 1.00 — the sized withdraw
    /// then failed Aave's own health check, bricking the de-risking path exactly when it is needed.
    /// The quote's contract is that it is executable: repay the loose leg, then withdraw the quote, in
    /// the exact order the repay flow runs them.
    function test_repayWithdrawable_quoteExecutableWhileUnderwater() public {
        // weETH collateral plus a supplied USDC pot for the withdraw leg to draw on, levered to ~98% of
        // raw capacity; a 15% weETH crash then parks the position under Aave's 1.00 bound.
        _supplyToGateway(address(safe), address(weETH), 0.2 ether);
        _supplyToGateway(address(safe), address(usdc), 500e6);
        _borrowOnGateway(address(safe), address(usdc), (gw.rawBorrowCapacity(address(safe), address(usdc)) * 98) / 100, recipient);
        _crashWeethAavePrice(8500);
        assertLt(spoke.getUserAccountData(address(safe)).healthFactor, 1e18, "underwater");

        // A loose repay larger than the deficit frees real headroom, so the quote must be non-zero
        uint256 fromLoose = 200e6;
        uint256 quote = LendSourcingLib.repayWithdrawable(gw, address(safe), address(usdc), fromLoose);
        assertGt(quote, 0, "freed headroom beyond the deficit is quotable");

        deal(address(usdc), address(safe), fromLoose);
        vm.startPrank(driver);
        gw.repay(address(safe), address(usdc), fromLoose);
        gw.withdraw(address(safe), address(usdc), quote, address(safe));
        vm.stopPrank();

        assertGe(spoke.getUserAccountData(address(safe)).healthFactor, 1e18, "executed quote respects Aave's bound");
    }

    /// At max leverage the supplied pot alone cannot fund a repay (Aave's health check caps the withdraw),
    /// but topping up loose unlocks more: the loose leg repays first and frees headroom for the withdraw.
    function test_repay_unloopsAtMaxLeverageWithLooseTopUp() public {
        uint256 suppliedUsdc = 1000e6;
        uint256 borrowedUsdc = 799e6; // a hair under the 80% CF max: headroom ~0
        _buildGatewayPosition(address(safe), address(usdc), suppliedUsdc, address(usdc), borrowedUsdc);

        // Nothing loose and no headroom to withdraw against: the repay cannot be sourced
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.repay(address(safe), address(usdc), 100e6);

        // The loose top-up funds twice its size: its repay frees that much USD of headroom, letting the
        // supplied leg withdraw the other half
        uint256 topUpUsdc = 100e6;
        uint256 repayAmt = 2 * topUpUsdc;
        deal(address(usdc), address(safe), topUpUsdc);
        uint256 repayUsd = debtManager.convertCollateralTokenToUsd(address(usdc), repayAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), repayUsd);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowedUsdc - repayAmt, 3, "unlooped by loose plus freed-headroom withdraw");
        assertApproxEqAbs(usdc.balanceOf(address(safe)), 0, 3, "loose fully consumed");
    }

    /// When the supplied pot can fund the repay, the pending withdrawal request survives and its reserved
    /// loose balance is untouched.
    function test_repay_prefersSuppliedOverReservedLoose() public {
        uint256 borrowedUsdc = 300e6;
        uint256 suppliedUsdc = 1000e6; // covers the whole repay, so the reserved loose is never needed
        uint256 reservedUsdc = 200e6;
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowedUsdc);
        _supplyToGateway(address(safe), address(usdc), suppliedUsdc);
        deal(address(usdc), address(safe), reservedUsdc);
        _requestWithdrawal(_addr1(address(usdc)), _uint1(reservedUsdc), withdrawRecipient);

        uint256 repayUsd = debtManager.convertCollateralTokenToUsd(address(usdc), borrowedUsdc);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), repayUsd);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 0, 3, "debt repaid");
        assertEq(usdc.balanceOf(address(safe)), reservedUsdc, "reserved loose untouched");
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), reservedUsdc, "withdrawal request survived");
    }

    /// With no supplied balance to draw on, the repay wins the competing claim: the withdrawal request is
    /// cancelled and its reserved loose balance funds the repay.
    function test_repay_cancelsWithdrawalAsLastResort() public {
        uint256 borrowedUsdc = 300e6;
        uint256 reservedUsdc = 200e6; // the safe's only USDC, all reserved; no supplied USDC to draw on
        uint256 repayAmt = 150e6;
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowedUsdc);
        deal(address(usdc), address(safe), reservedUsdc);
        _requestWithdrawal(_addr1(address(usdc)), _uint1(reservedUsdc), withdrawRecipient);

        uint256 repayUsd = debtManager.convertCollateralTokenToUsd(address(usdc), repayAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), repayUsd);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), borrowedUsdc - repayAmt, 3, "repaid from the reserved balance");
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 0, "withdrawal request cancelled");
    }

    /// Freezing the reserve blocks new borrows but never repayment: the repay gates on registration, not
    /// borrowability, and Aave allows both the repay and its supplied-leg withdraw while frozen.
    function test_repay_worksWhileReserveFrozen() public {
        uint256 borrowedUsdc = 1000e6;
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowedUsdc);
        // Part loose, part supplied, so both repay legs run against the frozen reserve
        _supplyToGateway(address(safe), address(usdc), 600e6);
        deal(address(usdc), address(safe), 500e6);

        _setAaveReserveFrozen(usdcReserveId, true);
        assertFalse(gw.isBorrowable(address(usdc)), "frozen reserve no longer borrowable");

        uint256 debt = gw.debtOf(address(safe), address(usdc));
        uint256 debtUsd = debtManager.convertCollateralTokenToUsd(address(usdc), debt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), debtUsd);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 0, 2, "debt repaid from loose plus supplied while frozen");
    }

    // ----------------------------------------------------------------- freed-headroom credit (repayValue)

    /// repayValue is an exact lower bound on the headroom an actual repay frees: Aave restores drawn shares
    /// rounded down, so the ideal borrowValue credit can overstate the freed cover by a share — crediting it
    /// would let an exact-boundary repay overshoot Aave's health check on its withdraw leg.
    function testFuzz_repayValue_lowerBoundsActualFreedHeadroom(uint256 repayBps, uint256 accrual) public {
        repayBps = bound(repayBps, 100, 9900);
        accrual = bound(accrual, 1 hours, 20 days); // off round numbers, within oracle staleness
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), 2000e6);
        vm.warp(block.timestamp + accrual);

        uint256 repayAmt = (gw.debtOf(address(safe), address(usdc)) * repayBps) / 10_000;
        uint256 credited = gw.repayValue(address(safe), address(usdc), repayAmt);
        assertLe(credited, gw.borrowValue(address(usdc), repayAmt), "restore rounding can only lower the credit");

        uint256 headroomBefore = gw.rawWithdrawHeadroom(address(safe));
        deal(address(usdc), address(safe), repayAmt);
        vm.prank(driver);
        gw.repay(address(safe), address(usdc), repayAmt);
        uint256 freed = gw.rawWithdrawHeadroom(address(safe)) - headroomBefore;

        assertGe(freed, credited, "credit never exceeds the actually freed headroom");
        assertLe(freed - credited, 1, "and is exact up to the required-cover ceil");
    }

    /// The exact max-sourcing quote (loose leg first, repayWithdrawable-sized withdraw leg) executes after
    /// interest accrual: CashLendLib.repay's leg order with the sizing's own numbers, straight on Aave.
    function testFuzz_repay_exactMaxSourcingQuoteExecutes(uint256 accrual) public {
        accrual = bound(accrual, 1 hours, 20 days);
        // Borrow near the position's power so the headroom cap, not the supplied balance, binds the quote
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        _supplyToGateway(address(safe), address(usdc), 3000e6);
        _borrowOnGateway(address(safe), address(usdc), (gw.getAccountData(address(safe)).availableBorrowsUsd * 90) / 100, recipient);
        vm.warp(block.timestamp + accrual);

        uint256 fromLoose = 500e6;
        uint256 quote = LendSourcingLib.repayWithdrawable(gw, address(safe), address(usdc), fromLoose);
        assertGt(quote, 0, "position quotes a supplied leg");
        assertLt(quote, gw.suppliedOf(address(safe), address(usdc)), "the headroom cap binds the quote");

        deal(address(usdc), address(safe), fromLoose);
        vm.startPrank(driver);
        gw.repay(address(safe), address(usdc), fromLoose);
        gw.withdraw(address(safe), address(usdc), quote, address(safe));
        vm.stopPrank();
        assertGe(spoke.getUserAccountData(address(safe)).healthFactor, 1e18, "exact quote lands at or above Aave's bound");
    }

    function _uint1(uint256 a) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = a;
        return arr;
    }
}
