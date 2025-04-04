// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CashEventEmitter, CashModuleTestSetup, IERC20, IDebtManager, ICashModule, Mode } from "../CashModuleTestSetup.t.sol";

contract DebtManagerRepayTest is CashModuleTestSetup {
    uint256 collateralAmount = 0.01 ether;
    uint256 collateralValueInUsdc;
    uint256 borrowAmt;

    function setUp() public override {
        super.setUp();

        vm.prank(owner);
        cashModule.setDelays(60, 3600, 0); // set credit mode delay to 0

        _setMode(Mode.Credit);

        deal(address(weETHScroll), address(safe), collateralAmount);

        collateralValueInUsdc = debtManager.convertCollateralTokenToUsd(address(weETHScroll), collateralAmount);

        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe)) / 2;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmt;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);
    }

    function test_repay_works() public {
        uint256 debtAmtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertGt(debtAmtBefore, 0);

        uint256 repayAmt = debtAmtBefore;
        deal(address(usdcScroll), address(safe), repayAmt);
        vm.startPrank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.RepayDebtManager(address(safe), address(usdcScroll), repayAmt, repayAmt);
        cashModule.repay(address(safe), address(usdcScroll), repayAmt);
        vm.stopPrank();

        uint256 debtAmtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertEq(debtAmtBefore - debtAmtAfter, repayAmt);
    }

     function test_repay_partial_amount_works() public {
        uint256 debtAmtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertGt(debtAmtBefore, 0);

        // Repay only half of the debt
        uint256 repayAmt = debtAmtBefore / 2;
        deal(address(usdcScroll), address(safe), repayAmt);
        
        vm.startPrank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.RepayDebtManager(address(safe), address(usdcScroll), repayAmt, repayAmt);
        cashModule.repay(address(safe), address(usdcScroll), repayAmt);
        vm.stopPrank();

        uint256 debtAmtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertApproxEqAbs(debtAmtBefore - debtAmtAfter, repayAmt, 1);
        assertApproxEqAbs(debtAmtAfter, repayAmt, 1); // Half of the debt remains
    }

    function test_repay_more_than_debt_only_repays_debt() public {
        uint256 debtAmtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertGt(debtAmtBefore, 0);

        // Try to repay twice the debt amount
        uint256 repayAmt = debtAmtBefore * 2;
        deal(address(usdcScroll), address(safe), repayAmt);
        
        vm.startPrank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), repayAmt);
        vm.stopPrank();

        // Should have only repaid the actual debt amount
        uint256 debtAmtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertEq(debtAmtAfter, 0);
        
        // Check that only the actual debt was transferred, not the excess
        uint256 remainingBalance = IERC20(address(usdcScroll)).balanceOf(address(safe));
        assertApproxEqAbs(remainingBalance, repayAmt - debtAmtBefore, 1);
    }

    function test_repay_faile_whenAmountIsZero() public {
        vm.startPrank(address(safe));
        vm.expectRevert(IDebtManager.RepaymentAmountIsZero.selector);
        debtManager.repay(address(safe), address(usdcScroll), 0);
        vm.stopPrank();
    }

    function test_repay_by_third_party_works() public {
        address thirdParty = makeAddr("thirdParty");
        uint256 debtAmtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));
        
        // Third party repays on behalf of the safe
        deal(address(usdcScroll), thirdParty, debtAmtBefore);
        
        vm.startPrank(thirdParty);
        IERC20(address(usdcScroll)).approve(address(debtManager), debtAmtBefore);
        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Repaid(address(safe), thirdParty, address(usdcScroll), debtAmtBefore);
        debtManager.repay(address(safe), address(usdcScroll), debtAmtBefore);
        vm.stopPrank();
        
        uint256 debtAmtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertEq(debtAmtAfter, 0);
    }

    function test_repay_affects_borrowingCapacity() public {
        uint256 capacityBefore = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        
        uint256 debtAmtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));
        deal(address(usdcScroll), address(safe), debtAmtBefore);
        
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), debtAmtBefore);
        
        uint256 capacityAfter = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        
        // Capacity should increase by approximately the amount repaid
        assertApproxEqAbs(capacityAfter, capacityBefore + debtAmtBefore, 1);
    }

    function test_repay_updates_totalBorrowingAmounts() public {
        (IDebtManager.TokenData[] memory beforeTokenData, uint256 beforeTotalAmount) = debtManager.totalBorrowingAmounts();
        
        uint256 debtAmtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));
        deal(address(usdcScroll), address(safe), debtAmtBefore);
        
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), debtAmtBefore);
        
        (IDebtManager.TokenData[] memory afterTokenData, uint256 afterTotalAmount) = debtManager.totalBorrowingAmounts();
        
        // Total borrowing amount should decrease by approximately the amount repaid
        assertApproxEqAbs(beforeTotalAmount - afterTotalAmount, debtAmtBefore, 1);
        
        // If this was the only debt for this token, it might be removed from the array
        if (afterTokenData.length < beforeTokenData.length) {
            assertEq(afterTokenData.length, beforeTokenData.length - 1);
        } else {
            // Otherwise, the token's amount should be reduced
            for (uint i = 0; i < afterTokenData.length; i++) {
                if (afterTokenData[i].token == address(usdcScroll)) {
                    assertApproxEqAbs(
                        beforeTokenData[i].amount - afterTokenData[i].amount, 
                        debtAmtBefore, 
                        1
                    );
                    break;
                }
            }
        }
    }

    function test_repay_fails_nonEtherFiSafe() public {
        uint256 debtAmt = debtManager.borrowingOf(address(safe), address(usdcScroll));
        deal(address(usdcScroll), address(this), debtAmt);
        
        vm.expectRevert(IDebtManager.OnlyEtherFiSafe.selector);
        debtManager.repay(makeAddr("notSafe"), address(usdcScroll), debtAmt);
    }

    function test_repay_fails_withNonBorrowToken() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyBorrowToken.selector);
        cashModule.repay(address(safe), address(weETHScroll), 1 ether);
    }

    function test_repay_incursInterest() public {
        uint256 timeElapsed = 10;

        vm.warp(block.timestamp + timeElapsed);
        uint256 expectedInterest = (borrowAmt * borrowApyPerSecond * timeElapsed) / 1e20;
        uint256 debtAmtBefore = borrowAmt + expectedInterest;

        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdcScroll)), debtAmtBefore, 1);
        uint256 repayAmt = debtAmtBefore;
        deal(address(usdcScroll), address(safe), repayAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), repayAmt);

        uint256 debtAmtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertApproxEqAbs(debtAmtBefore - debtAmtAfter, repayAmt, 1);
    }

    function test_repay_fails_whenBalanceIsInsufficient() public {
        deal(address(usdcScroll), address(safe), 0);

        vm.startPrank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.repay(address(safe), address(usdcScroll), 1);
        vm.stopPrank();
    }
}
