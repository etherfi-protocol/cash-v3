// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { ICashModule, Mode, BinSponsor } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { SpendingLimitLib } from "../../../../src/libraries/SpendingLimitLib.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import { UpgradeableProxy } from "../../../../src/utils/UpgradeableProxy.sol";

contract CashModuleSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_spend_works_inDebitMode() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Debit);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), 0);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherBalBefore + amount);
    }

    function test_spend_worksWithMultipleToken_inDebitMode() public {
        vm.prank(owner);
        debtManager.supportBorrowToken(address(weETHScroll), borrowApyPerSecond, minShares);

        uint256 amountInUsd = 100e6;
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdcScroll), amountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETHScroll), amountInUsd);

        deal(address(usdcScroll), address(safe), usdcAmount);
        deal(address(weETHScroll), address(safe), weETHAmount);


        uint256 settlementDispatcherUsdcBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));
        uint256 settlementDispatcherWeETHBalBefore = weETHScroll.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdcScroll);
        spendTokens[1] = address(weETHScroll);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = amountInUsd;
        spendAmounts[1] = amountInUsd;

        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = usdcAmount;
        tokenAmounts[1] = weETHAmount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, tokenAmounts, spendAmounts, amountInUsd + amountInUsd, Mode.Debit);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), 0);
        assertEq(weETHScroll.balanceOf(address(safe)), 0);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherUsdcBalBefore + usdcAmount);
        assertEq(weETHScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherWeETHBalBefore + weETHAmount);
    }


    function test_spend_works_inCreditMode() public {
        uint256 initialBalance = 100e6;
        deal(address(usdcScroll), address(safe), initialBalance);

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));
        uint256 debtManagerBalBefore = usdcScroll.balanceOf(address(debtManager));

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Credit);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), initialBalance);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherBalBefore + amount);
        assertEq(usdcScroll.balanceOf(address(debtManager)), debtManagerBalBefore - amount);
    }

    function test_spend_failsWithMultipleTokens_inCreditMode() public {
        uint256 initialBalance = 100e6;
        deal(address(usdcScroll), address(safe), initialBalance);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdcScroll);
        spendTokens[1] = address(weETHScroll);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = amount;
        spendAmounts[1] = amount;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyOneTokenAllowedInCreditMode.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }

    function test_spend_reverts_whenTransactionAlreadyCleared() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        // Mark transaction as cleared
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Try to spend again with the same txId
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.TransactionAlreadyCleared.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }

    function test_spend_reverts_whenUnsupportedToken() public {
        // Setup mock token that is not a borrow token
        address mockToken = makeAddr("mockToken");

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = mockToken;
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 100e6;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.UnsupportedToken.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }

    function test_spend_reverts_whenAmountIsZero() public {
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 0;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.AmountZero.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }

    function test_spend_reverts_whenNotEtherFiWallet() public {
        address notEtherFiWallet = makeAddr("notEtherFiWallet");

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 100e6;

        vm.prank(notEtherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(ICashModule.OnlyEtherFiWallet.selector));
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
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

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;

        // Spend should work and account for the pending withdrawal
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify tokens were transferred
        assertEq(usdcScroll.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherBalBefore + spendAmount);

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

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmt;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        uint256 maxCanWithdraw = 10e6;
        tokens[0] = address(usdcScroll);
        amounts[0] = maxCanWithdraw;
        _requestWithdrawal(tokens, amounts, recipient);

        uint256 settlementDispatcherUsdcBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));

        spendAmounts[0] = futureBorrowAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalCancelled(address(safe), tokens, amounts, withdrawRecipient);
        cashModule.spend(address(safe), address(0), address(0), keccak256("newTxId"), BinSponsor.Reap, spendTokens, spendAmounts, true);

        uint256 settlementDispatcherUsdcBalAfter = usdcScroll.balanceOf(address(settlementDispatcherReap));

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

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;

        // Spend should work and cancel the withdrawal
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalAmountUpdated(address(safe), address(usdcScroll), initialAmount - spendAmount);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify tokens were transferred
        assertEq(usdcScroll.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherBalBefore + spendAmount);

        // Verify pending withdrawal was cancelled
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), initialAmount - spendAmount);
    }

    function test_spend_respectsSpendingLimits() public {
        deal(address(usdcScroll), address(safe), 1e12);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = dailyLimitInUsd + 1;

        // Try to spend more than daily limit
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        spendAmounts[0] = dailyLimitInUsd / 2;

        // Spend within limit should work
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), keccak256("txId2"), BinSponsor.Reap, spendTokens, spendAmounts, true);

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

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 10e6;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        _setMode(Mode.Debit);

        spendAmounts[0] = safeBalUsdc;

        vm.prank(etherFiWallet);
        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        cashModule.spend(address(safe), address(0), address(0), keccak256("newTxId"), BinSponsor.Reap, spendTokens, spendAmounts, true);
    }
    
    function test_spend_inDebitMode_cancelsWithdrawal_whenBorrowExceedsMaxBorrowAfterSpending() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 safeBalUsdc = 1000e6;
        uint256 safeBalWeETH = 1 ether;
        deal(address(usdcScroll), address(safe), safeBalUsdc);
        deal(address(weETHScroll), address(safe), safeBalWeETH);
        deal(address(usdcScroll), address(debtManager), 1000e6);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 10e6;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        _setMode(Mode.Debit);

        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(weETHScroll);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = safeBalWeETH;
        address recipient = makeAddr("alice");
        _requestWithdrawal(withdrawTokens, withdrawAmounts, recipient);    

        spendAmounts[0] = safeBalUsdc;

        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(weETHScroll)), safeBalWeETH);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalCancelled(address(safe), withdrawTokens, withdrawAmounts, recipient);
        cashModule.spend(address(safe), address(0), address(0), keccak256("newTxId"), BinSponsor.Reap, spendTokens, spendAmounts, true);
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(weETHScroll)), 0);
    }

    function test_spend_reverts_whenArrayLengthMismatch() public {
        // Create mismatched arrays
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdcScroll);
        spendTokens[1] = address(weETHScroll);
        
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 100e6;
        
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.ArrayLengthMismatch.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }
    
    function test_spend_reverts_whenEmptyTokensArray() public {
        // Create empty tokens array
        address[] memory spendTokens = new address[](0);
        uint256[] memory spendAmounts = new uint256[](0);
        
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }
    
    function test_spend_withNoCashback() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        
        // Get initial token balances
        uint256 safeTokenBalBefore = scrToken.balanceOf(address(safe));
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        
        vm.prank(etherFiWallet);
        // Spend with shouldReceiveCashback set to false
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, false);
        
        // Verify no cashback was received
        assertEq(scrToken.balanceOf(address(safe)), safeTokenBalBefore);
    }
    
    function test_spend_withSpecificSpender() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        
        address spender = makeAddr("spender");
        uint256 spenderTokenBalBefore = scrToken.balanceOf(spender);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
        
        // Check if the spender received some cashback
        // The exact amount depends on configuration but should be greater than initial
        assertGt(scrToken.balanceOf(spender), spenderTokenBalBefore);
    }
    
    function test_spend_whenPaused() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        
        // Pause the contract
        vm.prank(pauser);
        UpgradeableProxy(address(cashModule)).pause();
        
        // Attempt to spend while paused
        vm.prank(etherFiWallet);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
        
        // Unpause and verify it works again
        vm.prank(unpauser);
        UpgradeableProxy(address(cashModule)).unpause();
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }
    
    function test_spend_multiplesWithinLimits() public {
        uint256 smallAmount = dailyLimitInUsd / 5;
        deal(address(usdcScroll), address(safe), 1 ether);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        
        // Perform multiple spends
        for (uint i = 0; i < 4; i++) {
            spendAmounts[0] = smallAmount;
            bytes32 currentTxId = keccak256(abi.encodePacked("txId", i));
            
            vm.prank(etherFiWallet);
            cashModule.spend(address(safe), address(0), address(0), currentTxId, BinSponsor.Reap, spendTokens, spendAmounts, true);
        }
        
        // This spend should exceed the daily limit
        spendAmounts[0] = smallAmount + 1;
        bytes32 finalTxId = keccak256(abi.encodePacked("txId-final"));
        
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), address(0), address(0), finalTxId, BinSponsor.Reap, spendTokens, spendAmounts, true);
        
        // Advance time to next day (considering timezone offset)
        uint256 timeToAdd = 24 hours;
        vm.warp(block.timestamp + timeToAdd);
        
        // Now the spend should work as daily limit resets
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), finalTxId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }
        
    function test_spend_revertWhenSafeIsSpender() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.spend(address(safe), address(safe), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }
    
    function test_spend_inDebitModeWithInsufficientBalance() public {
        uint256 amount = 100e6;
        uint256 availableAmount = 50e6;
        deal(address(usdcScroll), address(safe), availableAmount);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }

    function test_settlementDispatcherView() public view {
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Reap), address(settlementDispatcherReap));
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Rain), address(settlementDispatcherRain));
    }

    function test_spend_FundsGoToBinSponsorSettlementDispatcherAsSpecified_inDebitMode() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), 2 * amount);

        uint256 settlementDispatcherReapBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Debit);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), amount);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherReapBalBefore + amount);

        uint256 settlementDispatcherRainBalBefore = usdcScroll.balanceOf(address(settlementDispatcherRain));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Debit);
        cashModule.spend(address(safe), address(0), address(0), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId2")));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), 0);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherRain)), settlementDispatcherRainBalBefore + amount);
    }

    function test_spend_FundsGoToBinSponsorSettlementDispatcherAsSpecified_inCreditMode() public {
        uint256 initialBalance = 100e6;
        deal(address(usdcScroll), address(safe), initialBalance);

        uint256 settlementDispatcherReapBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));
        uint256 debtManagerBalBefore = usdcScroll.balanceOf(address(debtManager));

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Credit);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), initialBalance);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), settlementDispatcherReapBalBefore + amount);
        assertEq(usdcScroll.balanceOf(address(debtManager)), debtManagerBalBefore - amount);

        uint256 settlementDispatcherRainBalBefore = usdcScroll.balanceOf(address(settlementDispatcherRain));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Credit);
        cashModule.spend(address(safe), address(0), address(0), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, true);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId2")));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), initialBalance);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherRain)), settlementDispatcherRainBalBefore + amount);
    }

    function test_spend_fails_whenDuplicateTokensArePassed() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdcScroll);
        spendTokens[1] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = amount;
        spendAmounts[1] = amount;

        vm.prank(etherFiWallet);
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
    }
}
