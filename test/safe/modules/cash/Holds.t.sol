// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { BinSponsor, Cashback, HoldAction, HoldRecord, ICashModule, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { CashHoldsLib } from "../../../../src/libraries/CashHoldsLib.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { SpendingLimitLib } from "../../../../src/libraries/SpendingLimitLib.sol";
import { CashEventEmitter } from "../../../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

/// @dev Shared setup. The base harness already wires CashModuleHolds; these tests only enable partial
///      settlement, which ships off by default.
contract HoldsTestSetup is CashModuleTestSetup {
    function setUp() public virtual override {
        super.setUp();
        vm.prank(owner);
        cashModule.setPartialSettlementEnabled(true);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _addHold(BinSponsor binSponsor, bytes32 _txId, uint256 amountUsd) internal {
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), binSponsor, _txId, amountUsd, HoldAction.AUTHORIZE);
    }

    function _forceAddHold(BinSponsor binSponsor, bytes32 _txId, uint256 amountUsd) internal {
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), binSponsor, _txId, amountUsd, HoldAction.FORCE_AUTHORIZE);
    }

    function _updateHold(BinSponsor binSponsor, bytes32 _txId, uint256 amountUsd) internal {
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), binSponsor, _txId, amountUsd, HoldAction.REAUTHORIZE);
    }

    function _releaseHold(BinSponsor binSponsor, bytes32 _txId) internal {
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), binSponsor, _txId, 0, HoldAction.RELEASE);
    }

    function _totalHeld() internal view returns (uint256) {
        (, uint256 totalHeldUsd, ) = cashModule.holdsOf(address(safe), BinSponsor.Reap, bytes32(0));
        return totalHeldUsd;
    }

    function _hold(BinSponsor binSponsor, bytes32 _txId) internal view returns (HoldRecord memory hold) {
        (hold, , ) = cashModule.holdsOf(address(safe), binSponsor, _txId);
    }

    function _heldAmount(BinSponsor binSponsor, bytes32 _txId) internal view returns (uint256) {
        return _hold(binSponsor, _txId).amountUsd;
    }

    function _spendableUsd() internal view returns (uint256) {
        (, , uint256 spendableUsd) = cashModule.holdsOf(address(safe), BinSponsor.Reap, bytes32(0));
        return spendableUsd;
    }

    /// @dev Settles `amountUsd` on-chain for `_txId`. Works with or without a prior hold: a settlement with
    ///      no hold is honored and charged in full.
    function _settle(bytes32 _txId, BinSponsor binSponsor, uint256 amountUsd) internal {
        vm.prank(etherFiWallet);
        _settleRaw(_txId, binSponsor, amountUsd);
    }

    /// @dev _settle without the prank, so a vm.expectRevert placed before it is consumed by spend() itself
    ///      rather than by the prank. The caller pranks.
    function _settleRaw(bytes32 _txId, BinSponsor binSponsor, uint256 amountUsd) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = amountUsd;
        Cashback[] memory cashbacks;

        cashModule.spend(address(safe), _txId, binSponsor, tokens, amountsInUsd, cashbacks);
    }

    /// @dev Builds sigs and calls requestWithdrawal directly — no internal getDelays() or expectEmit, so a
    ///      vm.expectRevert placed before this call is consumed by requestWithdrawal itself. The nonce MUST
    ///      be pre-computed before any vm.expectRevert, because safe.nonce() is an external call that would
    ///      otherwise consume it.
    function _requestWithdrawalRaw(uint256 nonce, address[] memory tokens, uint256[] memory amounts, address recipient) internal {
        bytes32 digestHash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, recipient)))
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, signers, signatures);
    }
}

// =============================================================================
// Unit tests: hold lifecycle (addHold, forceAddHold, updateHold, releaseHold, removeHold)
// =============================================================================

contract HoldsUnitTest is HoldsTestSetup {

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------



    // -------------------------------------------------------------------------
    // addHold
    // -------------------------------------------------------------------------

    function test_addHold_storesRecordAndIncrementsTotalHolds() public {
        uint256 amount = 100e6;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.HoldAdded(address(safe), BinSponsor.Reap, txId, amount, amount);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, amount, HoldAction.AUTHORIZE);

        assertEq(_totalHeld(), amount);

        HoldRecord memory hold = _hold(BinSponsor.Reap, txId);
        assertEq(hold.amountUsd, amount);
        assertEq(hold.chargedUsd, amount, "an authorized hold is charged to the limit in full");
        assertGt(hold.createdAt, 0);
    }

    function test_addHold_revertsOnDuplicate() public {
        uint256 amount = 100e6;
        _addHold(BinSponsor.Reap, txId, amount);

        vm.prank(etherFiWallet);
        vm.expectRevert(CashHoldsLib.DuplicateHold.selector);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, amount, HoldAction.AUTHORIZE);
    }

    function test_addHold_revertsOnZeroAmount() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(CashHoldsLib.InvalidAmount.selector);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.AUTHORIZE);
    }

    function test_addHold_revertsWhenExceedsDailyLimit() public {
        // daily limit = 10_000e6 — hold exceeds it so consumeSpendingLimit reverts
        uint256 exceedingAmount = 10_001e6;

        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, exceedingAmount, HoldAction.AUTHORIZE);
    }

    function test_addHold_revertsWhenNotEtherFiWallet() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 100e6, HoldAction.AUTHORIZE);
    }

    function test_addHold_providerCodeNamespacing_noCollisionBetweenProviders() public {
        uint256 amount = 100e6;
        _addHold(BinSponsor.Reap, txId, amount);

        // Same txId, different providerCode — should succeed (separate namespace)
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Rain, txId, amount, HoldAction.AUTHORIZE);

        assertEq(_totalHeld(), amount * 2);
    }

    // -------------------------------------------------------------------------
    // forceAddHold
    // -------------------------------------------------------------------------

    function test_forceAddHold_bypassesSpendableCheck_setsForcedTrue() public {
        uint256 exceedingAmount = 10_001e6; // beyond rawSpendable

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.HoldAdded(address(safe), BinSponsor.Reap, txId, exceedingAmount, 0);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, exceedingAmount, HoldAction.FORCE_AUTHORIZE);

        assertEq(_totalHeld(), exceedingAmount);

        HoldRecord memory hold = _hold(BinSponsor.Reap, txId);
        assertEq(hold.amountUsd, exceedingAmount);
        assertEq(hold.chargedUsd, 0, "a force-authorized hold is not charged until it settles");
    }

    function test_forceAddHold_revertsOnDuplicate() public {
        _addHold(BinSponsor.Reap, txId, 100e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(CashHoldsLib.DuplicateHold.selector);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 100e6, HoldAction.FORCE_AUTHORIZE);
    }

    // -------------------------------------------------------------------------
    // updateHold
    // -------------------------------------------------------------------------

    function test_updateHold_increase_updatesTotalHolds() public {
        uint256 initial = 100e6;
        uint256 increased = 200e6;

        _addHold(BinSponsor.Reap, txId, initial);
        assertEq(_totalHeld(), initial);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.HoldUpdated(address(safe), BinSponsor.Reap, txId, initial, increased);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, increased, HoldAction.REAUTHORIZE);

        assertEq(_totalHeld(), increased);
        assertEq(_hold(BinSponsor.Reap, txId).amountUsd, increased);
    }

    function test_updateHold_decrease_updatesTotalHolds() public {
        uint256 initial = 200e6;
        uint256 decreased = 100e6;

        _addHold(BinSponsor.Reap, txId, initial);

        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, decreased, HoldAction.REAUTHORIZE);

        assertEq(_totalHeld(), decreased);
        assertEq(_hold(BinSponsor.Reap, txId).amountUsd, decreased);
    }

    function test_updateHold_increase_revertsWhenExceedsDailyLimit() public {
        uint256 initial = 9_900e6;
        // After addHold(9_900), spentToday=9_900, remaining=100. Delta of 101 breaches limit.
        uint256 exceedingIncrease = 10_001e6;

        _addHold(BinSponsor.Reap, txId, initial);

        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, exceedingIncrease, HoldAction.REAUTHORIZE);
    }

    function test_updateHold_revertsOnHoldNotFound() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(CashHoldsLib.HoldNotFound.selector);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 100e6, HoldAction.REAUTHORIZE);
    }

    // -------------------------------------------------------------------------
    // releaseHold
    // -------------------------------------------------------------------------

    function test_releaseHold_reversal_decrementsAndDeletes() public {
        uint256 amount = 100e6;
        _addHold(BinSponsor.Reap, txId, amount);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.HoldReleased(address(safe), BinSponsor.Reap, txId, amount);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.RELEASE);

        assertEq(_totalHeld(), 0);
        assertEq(_hold(BinSponsor.Reap, txId).createdAt, 0);
    }

    function test_releaseHold_admin_works() public {
        uint256 amount = 100e6;
        _addHold(BinSponsor.Reap, txId, amount);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.HoldReleased(address(safe), BinSponsor.Reap, txId, amount);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.RELEASE);

        assertEq(_totalHeld(), 0);
    }

    function test_releaseHold_revertsOnHoldNotFound() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(CashHoldsLib.HoldNotFound.selector);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.RELEASE);
    }

    // -------------------------------------------------------------------------
    // removeHold (onlyCashModuleCore)
    // -------------------------------------------------------------------------




    // -------------------------------------------------------------------------
    // providerCodeFromBinSponsor
    // -------------------------------------------------------------------------


    // -------------------------------------------------------------------------
    // CashModuleSetters auth guards
    // -------------------------------------------------------------------------



}

// =============================================================================
// Integration tests: CashModule + PendingHoldsModule
// =============================================================================

contract HoldsIntegrationTest is HoldsTestSetup {

    // -------------------------------------------------------------------------
    // spend() integration
    // -------------------------------------------------------------------------

    function test_spend_withMatchingHold_removesHoldAndSettles() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        _addHold(BinSponsor.Reap, txId, amount);
        assertEq(_totalHeld(), amount);

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.HoldSettled(address(safe), BinSponsor.Reap, txId, amount, amount, 0);
        _settle(txId, BinSponsor.Reap, amount);

        assertEq(_totalHeld(), 0);
        assertEq(_hold(BinSponsor.Reap, txId).createdAt, 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_settlementWithNoHold_isHonoredAndChargedInFull() public {
        // A settlement can arrive with no hold behind it — a late presentment, or one the backend never
        // recorded. It is honored, and the limit is charged in full, because the limit is the primary risk
        // control and has to reflect funds leaving the safe.
        //
        // Note there is no HoldAdded here: nothing is owed after this settles, so no hold is ever written.
        // (The original design created a hold at settlement purely to delete it in the same transaction.)
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = _spendableUsd();

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.HoldSettled(address(safe), BinSponsor.Reap, txId, amount, amount, 0);
        _settle(txId, BinSponsor.Reap, amount);

        // Limit is charged the full settled amount (no longer bypassed)
        assertEq(_spendableUsd(), rawBefore - amount);
        // Hold is gone after settlement
        assertEq(_totalHeld(), 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_spend_settlementLessThanHold_creditsLimitDeltaBack() public {
        // Settlement < hold: the $50 over-auth is credited back to the spending limit.
        // settlementSyncHold updates hold 150→100, releasing $50 delta from spentToday/spentThisMonth.
        uint256 holdAmount = 150e6;  // hold was for $150
        uint256 settleAmount = 100e6; // settlement comes in at $100

        deal(address(usdc), address(safe), holdAmount);
        uint256 rawBefore = _spendableUsd();

        _addHold(BinSponsor.Reap, txId, holdAmount);
        // addHold consumed $150 from limit
        assertEq(_spendableUsd(), rawBefore - holdAmount);

        _settle(txId, BinSponsor.Reap, settleAmount);

        // $50 delta credited back: limit now reflects only $100 consumed
        assertEq(_totalHeld(), 0);
        assertEq(_spendableUsd(), rawBefore - settleAmount);
    }

    function test_spend_settlementExceedsHold_chargesOnlyDelta() public {
        // Tip / gratuity scenario: settlement > hold amount.
        // The hold pre-charged $100 at addHold. The extra $20 tip must be charged at settlement.
        uint256 holdAmount = 100e6;
        uint256 settleAmount = 120e6;

        deal(address(usdc), address(safe), settleAmount);
        uint256 rawBefore = _spendableUsd();

        _addHold(BinSponsor.Reap, txId, holdAmount);
        assertEq(_spendableUsd(), rawBefore - holdAmount);

        _settle(txId, BinSponsor.Reap, settleAmount);

        // The $20 delta must be charged: total limit consumed = $100 (hold) + $20 (delta) = $120
        assertEq(_spendableUsd(), rawBefore - settleAmount);
        assertEq(_totalHeld(), 0);
    }

    function test_spend_withForceAddHold_chargesFullLimitAtSettlement() public {
        // forceAddHold bypasses consumeSpendingLimit — limit is NOT charged at addHold time.
        // When spend() settles it, limitConsumed=false (hold.forced=true) so the full amount is charged.
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = _spendableUsd();

        // Force-add: no limit consumption
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, amount, HoldAction.FORCE_AUTHORIZE);
        assertEq(_spendableUsd(), rawBefore); // limit unchanged

        // Normal spend() clears the forced hold and NOW charges the limit
        _settle(txId, BinSponsor.Reap, amount);

        assertEq(_spendableUsd(), rawBefore - amount);
        assertEq(_totalHeld(), 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    // -------------------------------------------------------------------------
    // requestWithdrawal() guard
    // -------------------------------------------------------------------------

    function test_requestWithdrawal_blockedWhenHoldsExist() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        _addHold(BinSponsor.Reap, txId, amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // Pre-compute nonce BEFORE vm.expectRevert — safe.nonce() is an external call that would
        // otherwise consume the expectRevert before requestWithdrawal is reached.
        uint256 nonce = safe.nonce();
        vm.expectRevert(abi.encodeWithSignature("WithdrawalBlockedByPendingHolds()"));
        _requestWithdrawalRaw(nonce, tokens, amounts, withdrawRecipient);
    }

    function test_requestWithdrawal_allowedWhenNoHolds() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        // No holds — withdrawal should proceed normally
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);
    }

    function test_requestWithdrawal_allowedAfterHoldReleased() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        _addHold(BinSponsor.Reap, txId, amount);

        // Release hold first
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.RELEASE);

        // Now withdrawal should succeed
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);
    }

    // -------------------------------------------------------------------------
    // spend() — no-hold path (formerly "forceSpend")
    // -------------------------------------------------------------------------
    // In the unified design, spend() handles both hold-exists and no-hold settlement paths.
    // The no-hold path is "Settlement is KING": a forced hold is created and immediately removed,
    // and the spending limit is NOT charged (bypass).

    function test_spend_withNoHold_deductsBalanceAndChargesLimit() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 safeBalBefore = usdc.balanceOf(address(safe));
        uint256 dispatcherBalBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 rawBefore = _spendableUsd();

        _settle(txId, BinSponsor.Reap, amount);

        assertEq(usdc.balanceOf(address(safe)), safeBalBefore - debtManager.convertUsdToCollateralToken(address(usdc), amount));
        assertGt(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBalBefore);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
        // Limit IS charged the settled amount (no longer bypassed)
        assertEq(_spendableUsd(), rawBefore - amount);
    }

    function test_spend_withNoHold_emitsCorrectSpendEvent() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = amount;
        uint256 tokenAmount = debtManager.convertUsdToCollateralToken(address(usdc), amount);
        uint256[] memory tokenAmounts = new uint256[](1);
        tokenAmounts[0] = tokenAmount;
        Cashback[] memory cashbacks;
        Mode currentMode = cashModule.getMode(address(safe));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, tokens, tokenAmounts, amountsInUsd, amount, currentMode);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amountsInUsd, cashbacks);
    }

    function test_spend_withNoHold_doesNotAffectUnrelatedHold() public {
        // spend() on a different txId with no hold creates a forced hold for that txId and settles it.
        // The existing hold on the original txId must be unaffected.
        uint256 holdAmount = 100e6;
        uint256 spendAmount = 50e6;
        deal(address(usdc), address(safe), holdAmount + spendAmount);

        _addHold(BinSponsor.Reap, txId, holdAmount);
        assertEq(_totalHeld(), holdAmount);

        // spend() on a different txId (no-hold path) — creates and immediately removes a forced hold
        bytes32 noHoldTxId = keccak256("noHoldTxId");
        _settle(noHoldTxId, BinSponsor.Reap, spendAmount);

        // Original hold for txId is unaffected
        assertEq(_totalHeld(), holdAmount);
        assertTrue(cashModule.transactionCleared(address(safe), noHoldTxId));
    }

    function test_spend_afterForceAddHold_sameTxId_clearsHoldAndChargesLimit() public {
        // forceAddHold followed by spend() on the same txId clears the hold.
        // Unlike the no-hold path, the forced hold (forceAddHold) bypassed the limit at creation,
        // so spend() charges the full settlement amount to the spending limit.
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = _spendableUsd();

        // Force-capture: place a hold without a balance check (no limit consumption)
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, amount, HoldAction.FORCE_AUTHORIZE);
        assertEq(_totalHeld(), amount);
        assertEq(_spendableUsd(), rawBefore); // limit unchanged

        // Settlement via spend() — clears the forced hold and charges limit
        _settle(txId, BinSponsor.Reap, amount);

        assertEq(_totalHeld(), 0);
        assertEq(_hold(BinSponsor.Reap, txId).createdAt, 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
        // Forced hold: limit was NOT charged at forceAddHold, IS charged at settlement
        assertEq(_spendableUsd(), rawBefore - amount);
    }

    function test_releaseHoldThenSpend_settlementIsKing_consistentState() public {
        // After a hold is released (e.g. reversal), the settlement might still arrive.
        // spend() with no existing hold (Settlement is KING): creates a forced hold and settles.
        // Limit IS charged for the settled amount (the no-hold path no longer bypasses it).
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = _spendableUsd();
        _addHold(BinSponsor.Reap, txId, amount);

        // Admin releases the hold (e.g. force-capture recovery where hold is stale)
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.RELEASE);
        assertEq(_totalHeld(), 0);
        // releaseHold credits back the limit
        assertEq(_spendableUsd(), rawBefore);

        // Settlement arrives — no-hold path (Settlement is KING), limit charged for the settled amount
        _settle(txId, BinSponsor.Reap, amount);

        assertTrue(cashModule.transactionCleared(address(safe), txId));
        assertEq(_totalHeld(), 0);
        // Limit charged the settled amount
        assertEq(_spendableUsd(), rawBefore - amount);
    }

    // -------------------------------------------------------------------------
    // Integration: full flows
    // -------------------------------------------------------------------------

    function test_integration_fullAuthToSettlement() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        // 1. Auth acknowledged: add hold
        _addHold(BinSponsor.Reap, txId, amount);
        assertEq(_totalHeld(), amount);

        // 2. Settlement: spend removes hold
        _settle(txId, BinSponsor.Reap, amount);

        // 3. Hold cleared, transaction settled
        assertEq(_totalHeld(), 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_integration_reversalFlow() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = _spendableUsd();
        _addHold(BinSponsor.Reap, txId, amount);
        assertEq(_totalHeld(), amount);

        // Network reversal — hold released, limit credited back
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.RELEASE);
        assertEq(_totalHeld(), 0);
        assertEq(_spendableUsd(), rawBefore); // limit restored

        // Settlement arrives despite reversal: Settlement is KING — spend() uses no-hold path.
        // This creates a forced hold internally and settles, charging the limit for the settled amount.
        deal(address(usdc), address(safe), amount);
        _settle(txId, BinSponsor.Reap, amount);

        assertTrue(cashModule.transactionCleared(address(safe), txId));
        assertEq(_totalHeld(), 0);
        // No-hold path now charges the limit for the settled amount
        assertEq(_spendableUsd(), rawBefore - amount);
    }

    function test_integration_incrementalAuth() public {
        uint256 initial = 100e6;
        uint256 increased = 150e6;
        uint256 decreased = 120e6;

        _addHold(BinSponsor.Reap, txId, initial);
        assertEq(_totalHeld(), initial);

        // Incremental auth: amount goes up
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, increased, HoldAction.REAUTHORIZE);
        assertEq(_totalHeld(), increased);

        // Incremental auth: amount goes down
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, decreased, HoldAction.REAUTHORIZE);
        assertEq(_totalHeld(), decreased);
    }

    function test_integration_withdrawalGuard_addHoldThenBlockThenReleaseThenAllow() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        _addHold(BinSponsor.Reap, txId, amount);

        // Pre-compute nonce BEFORE vm.expectRevert — safe.nonce() is an external call that would
        // otherwise consume the expectRevert before requestWithdrawal is reached.
        uint256 nonce = safe.nonce();
        vm.expectRevert(abi.encodeWithSignature("WithdrawalBlockedByPendingHolds()"));
        _requestWithdrawalRaw(nonce, tokens, amounts, withdrawRecipient);

        // Release hold
        vm.prank(etherFiWallet);
        cashModule.applyHold(address(safe), BinSponsor.Reap, txId, 0, HoldAction.RELEASE);

        // Withdrawal now allowed — use _requestWithdrawal helper which also checks the emitted event
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
    }
}

// =============================================================================
// CashLens pending holds views
// =============================================================================

contract HoldsCanSpendTest is HoldsTestSetup {

    function test_rawSpendable_dropsByTheHoldAmount() public {
        // A hold is charged to the limit at addHold, so the remaining capacity drops immediately —
        // there is no separate "spendable minus holds" figure to read.
        uint256 before = _spendableUsd();
        uint256 holdAmount = 100e6;
        _addHold(BinSponsor.Reap, txId, holdAmount);
        assertEq(_spendableUsd(), before - holdAmount);
    }

    function test_canSpend_noHolds_returnsTrueWhenFits() public {
        // With no holds canSpend behaves identically to the pre-holds path
        uint256 amountUsd = 100e6;
        deal(address(usdc), address(safe), amountUsd);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;

        bytes32 newTxId = keccak256("canSpend_noHolds");
        (bool ok, ) = cashLens.canSpend(address(safe), newTxId, tokens, amounts);
        assertTrue(ok);
    }

    function test_canSpend_holdsMakeItExceed_returnsFalse() public {
        // Fill most of the capacity with a hold so the next auth cannot fit
        _addHold(BinSponsor.Reap, txId, 9_900e6);

        // 200 USD would push total (holds + amount) past the 10_000 USD daily limit
        uint256 amountUsd = 200e6;
        deal(address(usdc), address(safe), amountUsd);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;

        bytes32 newTxId = keccak256("canSpend_exceed");
        (bool ok, ) = cashLens.canSpend(address(safe), newTxId, tokens, amounts);
        assertFalse(ok);
    }

    function test_canSpend_holdsReduceCapacity_butAmountStillFits() public {
        uint256 existingHold = 500e6;
        _addHold(BinSponsor.Reap, txId, existingHold);

        // 300 USD fits within the remaining 9_500 USD capacity
        uint256 amountUsd = 300e6;
        deal(address(usdc), address(safe), amountUsd);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;

        bytes32 newTxId = keccak256("canSpend_fits");
        (bool ok, ) = cashLens.canSpend(address(safe), newTxId, tokens, amounts);
        assertTrue(ok);
    }

    function test_totalPendingHolds_tracksTheOnChainHold() public {
        // totalPendingHolds is the withdrawal guard's sum. The remaining spending capacity is read
        // straight from rawSpendable, which the hold already reduced at addHold time.
        uint256 holdAmount = 250e6;
        uint256 rawBefore = _spendableUsd();
        _addHold(BinSponsor.Reap, txId, holdAmount);

        assertEq(_totalHeld(), holdAmount);
        assertEq(_spendableUsd(), rawBefore - holdAmount);
    }

    function test_totalPendingHolds_noHolds_isZero() public view {
        assertEq(_totalHeld(), 0);
    }
}

// =============================================================================
// Bytecode size gates — every CashModule implementation must stay under the EVM 24KB limit
// =============================================================================

contract CashModuleBytecodeSizeTest is Test {
    uint256 constant EIP170_LIMIT = 24_576;

    // Core, Setters and Holds are each deployed standalone as delegatecall targets, so EIP-170 applies to
    // all three. Holds work has been pushed outward twice to stay under it, so gate every hop.
    function test_cashModuleCore_deployedSize_underLimit() public {
        assertLt(address(new _CashModuleCoreForSizeCheck()).code.length, EIP170_LIMIT, "CashModuleCore exceeds the 24KB limit");
    }

    function test_cashModuleSetters_deployedSize_underLimit() public {
        assertLt(address(new _CashModuleSettersForSizeCheck()).code.length, EIP170_LIMIT, "CashModuleSetters exceeds the 24KB limit");
    }

    function test_cashModuleHolds_deployedSize_underLimit() public {
        assertLt(address(new _CashModuleHoldsForSizeCheck()).code.length, EIP170_LIMIT, "CashModuleHolds exceeds the 24KB limit");
    }
}

// Minimal deployment helpers — avoid importing the full constructor chain in this file
import { CashModuleCore } from "../../../../src/modules/cash/CashModuleCore.sol";
import { CashModuleHolds } from "../../../../src/modules/cash/CashModuleHolds.sol";
import { CashModuleSetters } from "../../../../src/modules/cash/CashModuleSetters.sol";

contract _CashModuleCoreForSizeCheck is CashModuleCore {
    constructor() CashModuleCore(address(1)) { }
}

contract _CashModuleSettersForSizeCheck is CashModuleSetters {
    constructor() CashModuleSetters(address(1)) { }
}

contract _CashModuleHoldsForSizeCheck is CashModuleHolds {
    constructor() CashModuleHolds(address(1)) { }
}
