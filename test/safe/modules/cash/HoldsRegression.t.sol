// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { BinSponsor, Cashback, HoldAction, ICashModule, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { HoldsTestSetup } from "./Holds.t.sol";

/**
 * @title HoldsRegressionTest
 * @notice Regression proofs for the three review findings on the original holds PR. Each asserts the
 *         correct behavior, so it fails against the pre-fix code and passes after.
 *
 *  1. A settlement that arrives with no hold ("settlement is king") must still charge the spending limit —
 *     the limit is the primary risk control, so it has to reflect funds leaving the safe.
 *  2. What an under-funded settlement could not pay must stay collectable, and collecting it must not
 *     charge the limit a second time.
 *  3. The withdrawal block must be re-checked when a withdrawal is finalized, not only when it is
 *     requested — a card transaction authorized during the delay window has a claim on those funds.
 *
 *  Plus the running invariant that the per-safe hold total always equals the sum of that safe's holds,
 *  across every path that can change either.
 */
contract HoldsRegressionTest is HoldsTestSetup {
    bytes32 constant INV_T1 = keccak256("inv-reap");
    bytes32 constant INV_T2 = keccak256("inv-rain");

    // ---------------------------------------------------------------------
    // 1. A settlement with no hold must charge the limit
    // ---------------------------------------------------------------------

    function test_settlementWithNoHold_chargesTheLimit() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 spendableBefore = _spendableUsd();

        _settle(txId, BinSponsor.Reap, amount);

        assertEq(_spendableUsd(), spendableBefore - amount, "a settlement with no hold must still charge the limit");
    }

    // ---------------------------------------------------------------------
    // 2. An under-funded settlement leaves a collectable remainder, charged once
    // ---------------------------------------------------------------------

    function test_underfundedSettlement_remainderIsCollectable_andChargedOnce() public {
        uint256 authorized = 100e6;
        deal(address(usdc), address(safe), 40e6); // the safe can only cover $40 of the $100 settlement

        uint256 spendableBefore = _spendableUsd();

        _addHold(BinSponsor.Reap, txId, authorized);
        assertEq(_spendableUsd(), spendableBefore - authorized, "authorizing charges the full amount");

        // $100 settles against a $40 balance: $40 moves, $60 stays owed as the hold.
        _settle(txId, BinSponsor.Reap, authorized);
        assertEq(_totalHeld(), 60e6, "the unpaid $60 stays held");
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // The user funds the safe and ops sweeps what is still owed.
        deal(address(usdc), address(safe), 60e6);
        vm.prank(etherFiWallet);
        cashModule.collectRemaining(address(safe), BinSponsor.Reap, txId, address(usdc));

        assertEq(_totalHeld(), 0, "collecting must clear the hold");
        assertEq(_spendableUsd(), spendableBefore - authorized, "collecting must not charge the limit twice");
    }

    // ---------------------------------------------------------------------
    // 3. The withdrawal block is enforced at finalize, not only at request
    // ---------------------------------------------------------------------

    function test_withdrawalBlock_isEnforcedAtFinalize() public {
        // Give withdrawals a delay so requesting and finalizing are distinct steps.
        (, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        vm.prank(owner);
        cashModule.setDelays(1 days, spendLimitDelay, modeDelay);

        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // Requested while nothing is held, so it passes the request-time check.
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // A card transaction is authorized during the delay window.
        _addHold(BinSponsor.Reap, txId, 50e6);

        // The delay elapses; finalizing must be blocked, because those funds are now claimed.
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSignature("WithdrawalBlockedByPendingHolds()"));
        cashModule.processWithdrawal(address(safe));
    }

    // ---------------------------------------------------------------------
    // Invariant: the safe's hold total always equals the sum of its holds
    // ---------------------------------------------------------------------

    function _sumHolds() internal view returns (uint256) {
        return _heldAmount(BinSponsor.Reap, INV_T1) + _heldAmount(BinSponsor.Rain, INV_T2);
    }

    function _assertHoldTotalMatchesSum() internal view {
        assertEq(_totalHeld(), _sumHolds(), "the safe's hold total drifted from the sum of its holds");
    }

    function test_holdTotalMatchesSumOfHolds_acrossTheLifecycle() public {
        deal(address(usdc), address(safe), 1_000e6);
        _assertHoldTotalMatchesSum(); // nothing held

        _addHold(BinSponsor.Reap, INV_T1, 300e6);
        _assertHoldTotalMatchesSum(); // 300
        _addHold(BinSponsor.Rain, INV_T2, 200e6);
        _assertHoldTotalMatchesSum(); // 500

        _updateHold(BinSponsor.Reap, INV_T1, 400e6); // re-authorized upward
        _assertHoldTotalMatchesSum(); // 600

        _updateHold(BinSponsor.Reap, INV_T1, 150e6); // re-authorized downward
        _assertHoldTotalMatchesSum(); // 350

        _releaseHold(BinSponsor.Rain, INV_T2); // reversed
        _assertHoldTotalMatchesSum(); // 150

        _settle(INV_T1, BinSponsor.Reap, 150e6); // settled in full
        _assertHoldTotalMatchesSum(); // 0
        assertEq(_totalHeld(), 0);
    }

    function test_holdTotalMatchesSumOfHolds_acrossPartialSettleThenCollect() public {
        deal(address(usdc), address(safe), 40e6);
        _addHold(BinSponsor.Reap, INV_T1, 100e6);
        _assertHoldTotalMatchesSum(); // 100

        _settle(INV_T1, BinSponsor.Reap, 100e6); // pays 40, leaves 60 owed
        _assertHoldTotalMatchesSum(); // 60
        assertEq(_totalHeld(), 60e6);

        deal(address(usdc), address(safe), 60e6);
        vm.prank(etherFiWallet);
        cashModule.collectRemaining(address(safe), BinSponsor.Reap, INV_T1, address(usdc));
        _assertHoldTotalMatchesSum(); // 0
        assertEq(_totalHeld(), 0);
    }

    // ---------------------------------------------------------------------
    // Partial settlement is off by default: the same settlement must revert
    // ---------------------------------------------------------------------

    function test_underfundedSettlement_revertsWhenPartialSettlementIsOff() public {
        vm.prank(owner);
        cashModule.setPartialSettlementEnabled(false);

        deal(address(usdc), address(safe), 40e6);
        _addHold(BinSponsor.Reap, txId, 100e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        _settleRaw(txId, BinSponsor.Reap, 100e6);
    }
}
