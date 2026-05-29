// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ICashModule, BinSponsor, Cashback, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { HoldRecord, IPendingHoldsModule, ReleaseReason } from "../../../../src/interfaces/IPendingHoldsModule.sol";
import { PendingHoldsModule } from "../../../../src/modules/cash/PendingHoldsModule.sol";
import { PendingHoldsTestSetup } from "./PendingHoldsModuleTest.t.sol";

/**
 * @title PendingHoldsFindings
 * @notice Proving tests for PR #120 review findings. Each asserts the *desired* (correct) behavior,
 *         so it is RED against the original code (proving the bug) and GREEN after the fix.
 *
 *  C2  — no-hold "Settlement is KING" path must charge the spending limit.
 *  C1  — under-funded settlement leftover must be collectable later via collectRemaining().
 *  M1  — the pending-holds withdrawal block must be enforced at finalize, not only at request.
 */
contract PendingHoldsFindingsTest is PendingHoldsTestSetup {

    // ---------------------------------------------------------------------
    // C2: no-hold settlement must charge the spending limit
    // ---------------------------------------------------------------------
    function test_C2_noHoldSettlement_chargesLimit() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        _spendWithoutHold(txId, BinSponsor.Reap, amount);

        // The limit is debited by the settled amount (no longer bypassed).
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - amount, "C2: no-hold settlement must charge limit");
    }

    // ---------------------------------------------------------------------
    // C1: under-funded settlement leaves a collectable remainder
    // ---------------------------------------------------------------------
    function test_C1_underfundedSettlement_remainderCollectable() public {
        uint256 authAmount = 100e6;
        uint256 funded = 40e6; // safe can only cover $40 of the $100 settlement
        deal(address(usdc), address(safe), funded);

        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        _addHold(BinSponsor.Reap, txId, authAmount);                 // limit charged $100
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - authAmount);

        // Settlement $100 against a $40 balance → partial: $40 moves, $60 remains as a forced hold.
        _spendWithHold(txId, BinSponsor.Reap, authAmount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 60e6, "C1: $60 remainder parked");
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // User later funds the safe; ops sweeps the remainder.
        deal(address(usdc), address(safe), 60e6);
        vm.prank(etherFiWallet);
        cashModule.collectRemaining(address(safe), txId, BinSponsor.Reap, address(usdc));

        // Remainder cleared → withdrawals unblock; limit reflects exactly $100 (no double charge).
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0, "C1: remainder must collect to 0");
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - authAmount, "C1: no double charge to limit");
    }

    // ---------------------------------------------------------------------
    // M1: withdrawal block must be enforced at finalize, not only at request
    // ---------------------------------------------------------------------
    function test_M1_withdrawalBlock_enforcedAtFinalize() public {
        // Give withdrawals a delay so request and finalize are distinct steps.
        (, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        vm.prank(owner);
        cashModule.setDelays(1 days, spendLimitDelay, modeDelay);

        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // Request a withdrawal while there are NO holds (passes the request-time guard).
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // A card hold appears during the delay window.
        _addHold(BinSponsor.Reap, txId, 50e6);

        // Delay elapses; finalize must be blocked because a hold now exists.
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSignature("WithdrawalBlockedByPendingHolds()"));
        cashModule.processWithdrawal(address(safe));
    }
}
