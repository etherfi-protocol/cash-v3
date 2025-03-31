// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";

import { ICashModule, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { SpendingLimitLib } from "../../../../src/libraries/SpendingLimitLib.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashModuleSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_spend_works_inDebitMode() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcher));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, address(usdcScroll), amount, amount, Mode.Debit);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), 0);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcher)), settlementDispatcherBalBefore + amount);
    }

    function test_spend_works_inCreditMode() public {
        uint256 initialBalance = 100e6;
        deal(address(usdcScroll), address(safe), initialBalance);

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcher));
        uint256 debtManagerBalBefore = usdcScroll.balanceOf(address(debtManager));

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, address(usdcScroll), amount, amount, Mode.Credit);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), initialBalance);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcher)), settlementDispatcherBalBefore + amount);
        assertEq(usdcScroll.balanceOf(address(debtManager)), debtManagerBalBefore - amount);
    }

    function test_spend_reverts_whenTransactionAlreadyCleared() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        // Mark transaction as cleared
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);

        // Try to spend again with the same txId
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.TransactionAlreadyCleared.selector);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);
    }

    function test_spend_reverts_whenUnsupportedToken() public {
        // Setup mock token that is not a borrow token
        address mockToken = makeAddr("mockToken");

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.UnsupportedToken.selector);
        cashModule.spend(address(safe), address(0), txId, mockToken, 100e6, true);
    }

    function test_spend_reverts_whenAmountIsZero() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.AmountZero.selector);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), 0, true);
    }

    function test_spend_reverts_whenNotEtherFiWallet() public {
        address notEtherFiWallet = makeAddr("notEtherFiWallet");

        vm.prank(notEtherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(ICashModule.OnlyEtherFiWallet.selector));
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), 100e6, true);
    }

    function test_spend_worksWithPendingWithdrawalInDebitMode() public {
        uint256 initialAmount = 200e6;
        uint256 spendAmount = 100e6;
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), initialAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcher));

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        // Spend should work and account for the pending withdrawal
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), spendAmount, true);

        // Verify tokens were transferred
        assertEq(usdcScroll.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcher)), settlementDispatcherBalBefore + spendAmount);

        // Verify pending withdrawal still exists
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);
    }

    function test_spend_cancelsPendingWithdrawalInCreditModeIfBlocked() public {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        address recipient = withdrawRecipient;
        uint256 futureBorrowAmt = 10e6;
        uint256 usdcCollateralAmount = 100e6;

        deal(address(usdcScroll), address(safe), usdcCollateralAmount);
        deal(address(usdcScroll), address(debtManager), 1 ether);

        uint256 totalMaxBorrow = debtManager.getMaxBorrowAmount(address(safe), true);
        uint256 borrowAmt = totalMaxBorrow - futureBorrowAmt;

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), borrowAmt, true);

        uint256 maxCanWithdraw = 10e6;
        tokens[0] = address(usdcScroll);
        amounts[0] = maxCanWithdraw;
        _requestWithdrawal(tokens, amounts, recipient);

        uint256 settlementDispatcherUsdcBalBefore = usdcScroll.balanceOf(address(settlementDispatcher));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalCancelled(address(safe), tokens, amounts, withdrawRecipient);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), futureBorrowAmt, true);

        uint256 settlementDispatcherUsdcBalAfter = usdcScroll.balanceOf(address(settlementDispatcher));

        assertEq(settlementDispatcherUsdcBalAfter - settlementDispatcherUsdcBalBefore, futureBorrowAmt);

        uint256 withdrawalAmt = cashLens.getPendingWithdrawalAmount(address(safe), address(usdcScroll));
        assertEq(withdrawalAmt, 0);
    }

    function test_spend_updatesWithdrawalRequestIfNecessary() public {
        uint256 initialAmount = 200e6;
        uint256 spendAmount = 150e6;
        uint256 withdrawalAmount = 100e6;
        deal(address(usdcScroll), address(safe), initialAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcher));

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Spend should work and cancel the withdrawal
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalAmountUpdated(address(safe), address(usdcScroll), initialAmount - spendAmount);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), spendAmount, true);

        // Verify tokens were transferred
        assertEq(usdcScroll.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcher)), settlementDispatcherBalBefore + spendAmount);

        // Verify pending withdrawal was cancelled
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), initialAmount - spendAmount);
    }

    function test_spend_respectsSpendingLimits() public {
        deal(address(usdcScroll), address(safe), 1e12);

        // Try to spend more than daily limit
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), dailyLimitInUsd + 1, true);

        // Spend within limit should work
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), keccak256("txId2"), address(usdcScroll), dailyLimitInUsd / 2, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId2")));
    }

    function test_spend_inDebitMode_fails_whenBorrowExceedsMaxBorrow() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 safeBalUsdc = 1000e6;
        deal(address(usdcScroll), address(safe), safeBalUsdc);
        deal(address(weETHScroll), address(safe), 0);
        deal(address(usdcScroll), address(debtManager), 1000e6);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), 10e6, true);

        _setMode(Mode.Debit);

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.BorrowingsExceedMaxBorrowAfterSpending.selector);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), safeBalUsdc, true);
    }
}
