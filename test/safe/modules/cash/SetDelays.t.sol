// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CashEventEmitter, ICashModule, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashModuleSetDelaysTest is CashModuleTestSetup {
    function test_setDelays_succeeds_whenCalledByController() public {
        // New values to set
        uint64 newWithdrawalDelay = 120; // 2 minutes
        uint64 newSpendLimitDelay = 7200; // 2 hours
        uint64 newModeDelay = 300; // 5 minutes

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.DelaysSet(newWithdrawalDelay, newSpendLimitDelay, newModeDelay);

        // Set new delays
        vm.prank(owner);
        cashModule.setDelays(newWithdrawalDelay, newSpendLimitDelay, newModeDelay);

        // Verify the values were updated
        (uint64 updatedWithdrawalDelay, uint64 updatedSpendLimitDelay, uint64 updatedModeDelay) = cashModule.getDelays();

        assertEq(updatedWithdrawalDelay, newWithdrawalDelay, "Withdrawal delay not updated correctly");
        assertEq(updatedSpendLimitDelay, newSpendLimitDelay, "Spend limit delay not updated correctly");
        assertEq(updatedModeDelay, newModeDelay, "Mode delay not updated correctly");
    }

    function test_setDelays_succeeds_whenSettingToZero() public {
        // Set all delays to zero
        uint64 newWithdrawalDelay = 0;
        uint64 newSpendLimitDelay = 0;
        uint64 newModeDelay = 0;

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.DelaysSet(newWithdrawalDelay, newSpendLimitDelay, newModeDelay);

        // Set new delays
        vm.prank(owner);
        cashModule.setDelays(newWithdrawalDelay, newSpendLimitDelay, newModeDelay);

        // Verify the values were updated
        (uint64 updatedWithdrawalDelay, uint64 updatedSpendLimitDelay, uint64 updatedModeDelay) = cashModule.getDelays();

        assertEq(updatedWithdrawalDelay, newWithdrawalDelay, "Withdrawal delay not updated correctly");
        assertEq(updatedSpendLimitDelay, newSpendLimitDelay, "Spend limit delay not updated correctly");
        assertEq(updatedModeDelay, newModeDelay, "Mode delay not updated correctly");
    }

    function test_setDelays_succeeds_whenSettingToMaxValue() public {
        // Set all delays to maximum uint64 value
        uint64 newWithdrawalDelay = type(uint64).max;
        uint64 newSpendLimitDelay = type(uint64).max;
        uint64 newModeDelay = type(uint64).max;

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.DelaysSet(newWithdrawalDelay, newSpendLimitDelay, newModeDelay);

        // Set new delays
        vm.prank(owner);
        cashModule.setDelays(newWithdrawalDelay, newSpendLimitDelay, newModeDelay);

        // Verify the values were updated
        (uint64 updatedWithdrawalDelay, uint64 updatedSpendLimitDelay, uint64 updatedModeDelay) = cashModule.getDelays();

        assertEq(updatedWithdrawalDelay, newWithdrawalDelay, "Withdrawal delay not updated correctly");
        assertEq(updatedSpendLimitDelay, newSpendLimitDelay, "Spend limit delay not updated correctly");
        assertEq(updatedModeDelay, newModeDelay, "Mode delay not updated correctly");
    }

    function test_setDelays_fails_whenCalledByNonController() public {
        // Initial values
        (uint64 initialWithdrawalDelay, uint64 initialSpendLimitDelay, uint64 initialModeDelay) = cashModule.getDelays();

        // New values to set
        uint64 newWithdrawalDelay = 120;
        uint64 newSpendLimitDelay = 7200;
        uint64 newModeDelay = 300;

        vm.prank(notOwner);
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.setDelays(newWithdrawalDelay, newSpendLimitDelay, newModeDelay);

        // Verify the values were not updated
        (uint64 updatedWithdrawalDelay, uint64 updatedSpendLimitDelay, uint64 updatedModeDelay) = cashModule.getDelays();

        assertEq(updatedWithdrawalDelay, initialWithdrawalDelay, "Withdrawal delay should not have changed");
        assertEq(updatedSpendLimitDelay, initialSpendLimitDelay, "Spend limit delay should not have changed");
        assertEq(updatedModeDelay, initialModeDelay, "Mode delay should not have changed");
    }
}
