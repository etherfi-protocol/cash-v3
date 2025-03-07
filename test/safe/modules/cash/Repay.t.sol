// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CashEventEmitter, CashModuleTestSetup, ICashModule, Mode } from "./CashModuleTestSetup.t.sol";

contract CashModuleRepayTest is CashModuleTestSetup {
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

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), borrowAmt, true);
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

    function test_repay_fails_withNonBorrowToken() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyBorrowToken.selector);
        cashModule.repay(address(safe), address(weETHScroll), 1 ether);
    }

    function test_repay_incursInterest() public {
        uint256 timeElapsed = 10;

        uint256 borrowApyPerSecond = debtManager.borrowApyPerSecond(address(usdcScroll));

        vm.warp(block.timestamp + timeElapsed);
        uint256 expectedInterest = (borrowAmt * borrowApyPerSecond * timeElapsed) / 1e20;
        uint256 debtAmtBefore = borrowAmt + expectedInterest;

        assertEq(debtManager.borrowingOf(address(safe), address(usdcScroll)), debtAmtBefore);
        uint256 repayAmt = debtAmtBefore;
        deal(address(usdcScroll), address(safe), repayAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), repayAmt);

        uint256 debtAmtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertEq(debtAmtBefore - debtAmtAfter, repayAmt);
    }

    function test_repay_fails_whenBalanceIsInsufficient() public {
        deal(address(usdcScroll), address(safe), 0);

        vm.startPrank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.repay(address(safe), address(usdcScroll), 1);
        vm.stopPrank();
    }
}
