// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Mode } from "../../../../src/interfaces/ICashModule.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashLensCanSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_canSpend_succeeds_inDebitMode_whenBalanceAvailable() public {
        uint256 bal = 100e6;
        deal(address(usdcScroll), address(safe), bal);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), bal);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_succeeds_inCreditMode_whenCollateralAvailable() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        deal(address(weETHScroll), address(safe), 1 ether);
        deal(address(usdcScroll), address(debtManager), 100e6);
        uint256 spendingAmt = 100e6;
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), spendingAmt);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenBalanceTooLow() public view {
        uint256 bal = usdcScroll.balanceOf(address(safe));
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), bal + 1);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient balance to spend with Debit flow");
    }

    function test_canSpend_fails_inCreditMode_whenLiquidityUnavailableInDebtManager() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        deal(address(weETHScroll), address(safe), 1 ether);
        uint256 spendingAmt = 100e6;
        deal(address(usdcScroll), address(debtManager), spendingAmt - 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), spendingAmt);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient liquidity in debt manager to cover the loan");
    }

    function test_canSpend_succeeds_inDebitMode_whenWithdrawalIsLowerThanAmountRequested() public {
        uint256 totalBal = 1000e6;
        uint256 withdrawalBal = 900e6;
        uint256 balToTransfer = totalBal - withdrawalBal;
        deal(address(usdcScroll), address(safe), totalBal);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalBal;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), balToTransfer);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_succeeds_inCreditMode_whenAfterWithdrawalAmountIsStillBorrowable() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        deal(address(usdcScroll), address(debtManager), 1 ether);
        uint256 totalBal = 1000e6;
        uint256 withdrawalAmt = 200e6;
        uint256 balToTransfer = 400e6; // still with 800 USDC after withdrawal we can borrow 400 USDC as ltv = 50%
        deal(address(usdcScroll), address(safe), totalBal);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmt;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), balToTransfer);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenWithdrawalRequestBlocksIt() public {
        address token = address(usdcScroll);
        uint256 bal = 100e6;
        deal(token, address(safe), bal);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, token, bal);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient effective balance after withdrawal to spend with debit mode");
    }

    function test_canSpend_fails_inCreditMode_whenWithdrawalRequestBlocksIt() public {
        address token = address(usdcScroll);
        uint256 bal = 100e6;
        deal(token, address(safe), bal);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        _setMode(Mode.Credit);

        // since we have 100 USDC and 10 is in withdrawal, also incoming mode is credit
        // with 90% ltv, max borrowable is (100 - 10) * 90% = 81 USDC
        // if we want to borrow 82 USDC, it should fail

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, token, 82e6);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient borrowing power");
    }

    function test_canSpend_fails_inCreditMode_whenCollateralBalanceIsZero() public {
        _setMode(Mode.Credit);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), 50e6);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient borrowing power");
    }

    function test_canSpend_fails_inDebitMode_whenWithdrawalRequestBlocksItWithMultipleTokens() public {
        address token = address(usdcScroll);
        uint256 bal = 100e6;
        deal(token, address(safe), bal);
        deal(address(weETHScroll), address(safe), bal);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weETHScroll);
        tokens[1] = token;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e6;
        amounts[1] = 10e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, token, bal);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient effective balance after withdrawal to spend with debit mode");
    }

    function test_canSpend_fails_whenTxIdIsAlreadyCleared() public {
        deal(address(usdcScroll), address(safe), 100 ether);
        uint256 amountToSpend = 100e6;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amountToSpend, true);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), amountToSpend);
        assertEq(canSpend, false);
        assertEq(reason, "Transaction already cleared");
    }

    function test_canSpend_fails_inDebitMode_whenDailySpendingLimitIsTooLow() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), amountToSpend);
        _updateSpendingLimit(amountToSpend - 1, 1 ether);

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), amountToSpend);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");
    }

    function test_canSpend_fails_inDebitMode_whenDailySpendingLimitIsExhausted() public {
        deal(address(usdcScroll), address(safe), 100 ether);
        uint256 amountToSpend = 100e6;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), dailyLimitInUsd - amountToSpend + 1, true);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), address(usdcScroll), amountToSpend);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");
    }

    function test_canSpend_succeeds_inDebitMode_whenSpendingLimitRenews() public {
        deal(address(usdcScroll), address(safe), 100 ether);
        uint256 amountToSpend = 100e6;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), dailyLimitInUsd - amountToSpend + 1, true);

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp + 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), address(usdcScroll), amountToSpend);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenIncomingDailySpendingLimitIsTooLow() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), amountToSpend);
        _updateSpendingLimit(amountToSpend - 1, 1 ether);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, address(usdcScroll), amountToSpend);
        assertEq(canSpend, false);
        assertEq(reason, "Incoming daily available spending limit less than amount requested");
    }

    function test_canSpend_fails_inDebitMode_whenIncomingDailySpendingLimitIsExhausted() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), 10 ether);
        _updateSpendingLimit(amountToSpend - 1, 1 ether);

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), 1, true);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), address(usdcScroll), amountToSpend);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp + 1);
        (canSpend, reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), address(usdcScroll), amountToSpend);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");
    }

    function test_canSpend_succeeds_inDebitMode_whenIncomingDailySpendingLimitRenews() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), 10 ether);
        _updateSpendingLimit(amountToSpend, 1 ether);

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), 1, true);

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp + 1);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), address(usdcScroll), amountToSpend);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenDailyLimitIsLowerThanAmountUsed() public {
        deal(address(usdcScroll), address(safe), 10 ether);

        uint256 amount = 100e6;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);

        _updateSpendingLimit(amount - 1, 1 ether);

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), address(usdcScroll), amount);
        assertEq(canSpend, false);
        assertEq(reason, "Daily spending limit already exhausted");
    }

    function test_canSpend_fails_inDebitMode_whenIncomingDailyLimitIsLowerThanAmountUsed() public {
        deal(address(usdcScroll), address(safe), 10 ether);

        uint256 amount = 100e6;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);

        _updateSpendingLimit(amount - 1, 1 ether);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), address(usdcScroll), amount);
        assertEq(canSpend, false);
        assertEq(reason, "Incoming daily spending limit already exhausted");
    }
}
