// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode } from "../../../../src/interfaces/ICashModule.sol";

import { SpendingLimit, SpendingLimitLib } from "../../../../src/libraries/SpendingLimitLib.sol";
import { CashModuleTestSetup, CashVerificationLib, IDebtManager, MessageHashUtils } from "./CashModuleTestSetup.t.sol";

contract CashModuleSpendingLimitTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_updateSpendingLimit_works() public {
        deal(address(usdcScroll), address(safe), 1000e6);

        uint256 dailySpendingLimitInUsd = 100e6;
        uint256 monthlySpendingLimitInUsd = 1000e6;
        uint256 transferAmount = 1e6;

        SpendingLimit memory spendingLimitBefore = cashLens.applicableSpendingLimit(address(safe));
        assertEq(spendingLimitBefore.dailyLimit, dailyLimitInUsd);
        assertEq(spendingLimitBefore.monthlyLimit, monthlyLimitInUsd);
        assertEq(spendingLimitBefore.spentToday, 0);
        assertEq(spendingLimitBefore.spentThisMonth, 0);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), transferAmount, true);

        spendingLimitBefore = cashLens.applicableSpendingLimit(address(safe));
        assertEq(spendingLimitBefore.spentToday, transferAmount);
        assertEq(spendingLimitBefore.spentThisMonth, transferAmount);

        _updateSpendingLimit(dailySpendingLimitInUsd, monthlySpendingLimitInUsd);

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();

        SpendingLimit memory spendingLimitAfterUpdate = cashLens.applicableSpendingLimit(address(safe));

        assertEq(spendingLimitAfterUpdate.dailyLimit, spendingLimitBefore.dailyLimit);
        assertEq(spendingLimitAfterUpdate.monthlyLimit, spendingLimitBefore.monthlyLimit);
        assertEq(spendingLimitAfterUpdate.newDailyLimit, dailySpendingLimitInUsd);
        assertEq(spendingLimitAfterUpdate.newMonthlyLimit, monthlySpendingLimitInUsd);
        assertEq(spendingLimitAfterUpdate.spentToday, transferAmount);
        assertEq(spendingLimitAfterUpdate.spentThisMonth, transferAmount);
        assertEq(spendingLimitAfterUpdate.dailyLimitChangeActivationTime, block.timestamp + spendingLimitDelay);
        assertEq(spendingLimitAfterUpdate.monthlyLimitChangeActivationTime, block.timestamp + spendingLimitDelay);

        vm.warp(block.timestamp + spendingLimitDelay + 1);
        SpendingLimit memory spendingLimitAfter = cashLens.applicableSpendingLimit(address(safe));
        assertEq(spendingLimitAfter.dailyLimit, dailySpendingLimitInUsd);
        assertEq(spendingLimitAfter.monthlyLimit, monthlySpendingLimitInUsd);
        assertEq(spendingLimitAfter.newDailyLimit, 0);
        assertEq(spendingLimitAfter.newMonthlyLimit, 0);
        assertEq(spendingLimitAfter.dailyLimitChangeActivationTime, 0);
        assertEq(spendingLimitAfter.monthlyLimitChangeActivationTime, 0);
    }

    function test_updateSpendingLimit_fails_whenDailyLimitIsGreaterThanMonthlyLimit() public {
        uint256 newDailyLimit = 100;
        uint256 newMonthlyLimit = newDailyLimit - 1;

        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 msgHash = keccak256(abi.encodePacked(CashVerificationLib.UPDATE_SPENDING_LIMIT_METHOD, block.chainid, address(safe), nonce, abi.encode(newDailyLimit, newMonthlyLimit))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, msgHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(SpendingLimitLib.DailyLimitCannotBeGreaterThanMonthlyLimit.selector);
        cashModule.updateSpendingLimit(address(safe), newDailyLimit, newMonthlyLimit, owner1, signature);
    }

    function test_updateSpendingLimit_doesNotDelay_whenDailyLimitIsGreater() public {
        uint256 newLimit = dailyLimitInUsd + 1;
        _updateSpendingLimit(newLimit, monthlyLimitInUsd);

        assertEq(cashLens.applicableSpendingLimit(address(safe)).dailyLimit, newLimit);
        assertEq(cashLens.applicableSpendingLimit(address(safe)).newDailyLimit, 0);
        assertEq(cashLens.applicableSpendingLimit(address(safe)).dailyLimitChangeActivationTime, 0);
    }

    function test_updateSpendingLimit_doesNotDelay_whenMonthlyLimitIsGreater() public {
        uint256 newLimit = monthlyLimitInUsd + 1;
        _updateSpendingLimit(dailyLimitInUsd, newLimit);

        assertEq(cashLens.applicableSpendingLimit(address(safe)).monthlyLimit, newLimit);
        assertEq(cashLens.applicableSpendingLimit(address(safe)).newMonthlyLimit, 0);
        assertEq(cashLens.applicableSpendingLimit(address(safe)).monthlyLimitChangeActivationTime, 0);
    }

    function test_SpendingLimitGetsRenewedAutomatically() public {
        SpendingLimit memory spendingLimit = cashLens.applicableSpendingLimit(address(safe));

        uint256 dailyLimit = spendingLimit.dailyLimit;
        uint256 amount = dailyLimit / 2;

        deal(address(usdcScroll), address(safe), 1 ether);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);
        
        assertEq(cashLens.applicableSpendingLimit(address(safe)).spentToday, amount);
        assertEq(cashLens.applicableSpendingLimit(address(safe)).spentThisMonth, amount);

        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), dailyLimit - amount + 1, true);

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp);
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), dailyLimit - amount + 1, true);

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp + 1);
        // Since the time for renewal is in the past, spentToday should be 0
        assertEq(cashLens.applicableSpendingLimit(address(safe)).spentToday, 0);
        assertEq(cashLens.applicableSpendingLimit(address(safe)).spentThisMonth, amount);
    }
}
