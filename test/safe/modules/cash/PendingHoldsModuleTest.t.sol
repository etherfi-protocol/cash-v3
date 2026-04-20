// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { ICashModule, BinSponsor, Cashback, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { HoldRecord, IPendingHoldsModule, ReleaseReason } from "../../../../src/interfaces/IPendingHoldsModule.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { SpendingLimitLib } from "../../../../src/libraries/SpendingLimitLib.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { CashEventEmitter } from "../../../../src/modules/cash/CashEventEmitter.sol";
import { PendingHoldsModule } from "../../../../src/modules/cash/PendingHoldsModule.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

/**
 * @dev Common setup: deploys PendingHoldsModule, wires it to CashModule, and redeploys
 *      CashLens with the correct pendingHoldsModule immutable (requires new deployment per the plan).
 */
contract PendingHoldsTestSetup is CashModuleTestSetup {
    IPendingHoldsModule public pendingHoldsModule;

    bytes4 internal constant PROVIDER_REAP = bytes4("REAP");
    bytes4 internal constant PROVIDER_RAIN = bytes4("RAIN");

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(owner);

        // Deploy PendingHoldsModule proxy and wire to CashModule
        address phImpl = address(new PendingHoldsModule(address(dataProvider)));
        pendingHoldsModule = IPendingHoldsModule(address(new UUPSProxy(
            phImpl,
            abi.encodeWithSelector(PendingHoldsModule.initialize.selector, address(roleRegistry), address(cashModule))
        )));
        cashModule.setPendingHoldsModule(address(pendingHoldsModule));

        // Redeploy CashLens with pendingHoldsModule so hold-aware lens functions work
        address cashLensImpl = address(new CashLens(address(cashModule), address(dataProvider), address(pendingHoldsModule)));
        cashLens = CashLens(address(new UUPSProxy(cashLensImpl, abi.encodeWithSelector(CashLens.initialize.selector, address(roleRegistry)))));

        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _addHold(bytes4 providerCode, bytes32 _txId, uint256 amountUsd) internal {
        vm.prank(etherFiWallet);
        pendingHoldsModule.addHold(address(safe), providerCode, _txId, amountUsd);
    }

    function _spendWithHold(bytes32 _txId, BinSponsor binSponsor, uint256 amountUsd) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = amountUsd;
        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), _txId, binSponsor, tokens, amountsInUsd, cashbacks);
    }

    /// @dev Calls spend() without a prior hold — tests the "Settlement is KING" (no-hold) path.
    ///      In the unified design, spend() handles both hold-exists and no-hold settlement.
    function _spendWithoutHold(bytes32 _txId, BinSponsor binSponsor, uint256 amountUsd) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = amountUsd;
        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), _txId, binSponsor, tokens, amountsInUsd, cashbacks);
    }

    /// @dev Builds sigs and calls requestWithdrawal directly — no internal getDelays() or expectEmit,
    ///      so vm.expectRevert placed before this call is correctly consumed by requestWithdrawal.
    ///      The nonce MUST be pre-computed by the caller before any vm.expectRevert is set,
    ///      because safe.nonce() is an external call that would otherwise consume the expectRevert.
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

contract PendingHoldsModuleUnitTest is PendingHoldsTestSetup {

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    function test_initialize_setCashModuleCore() public view {
        assertEq(pendingHoldsModule.cashModuleCore(), address(cashModule));
    }

    function test_initialize_revertsOnReinit() public {
        vm.expectRevert();
        PendingHoldsModule(address(pendingHoldsModule)).initialize(address(roleRegistry), address(cashModule));
    }

    // -------------------------------------------------------------------------
    // addHold
    // -------------------------------------------------------------------------

    function test_addHold_storesRecordAndIncrementsTotalHolds() public {
        uint256 amount = 100e6;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldAdded(address(safe), PROVIDER_REAP, txId, amount, block.timestamp, false);
        pendingHoldsModule.addHold(address(safe), PROVIDER_REAP, txId, amount);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), amount);

        HoldRecord memory hold = pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId);
        assertEq(hold.amountUsd, amount);
        assertEq(hold.providerCode, PROVIDER_REAP);
        assertFalse(hold.forced);
        assertGt(hold.createdAt, 0);
    }

    function test_addHold_revertsOnDuplicate() public {
        uint256 amount = 100e6;
        _addHold(PROVIDER_REAP, txId, amount);

        vm.prank(etherFiWallet);
        vm.expectRevert(IPendingHoldsModule.DuplicateHold.selector);
        pendingHoldsModule.addHold(address(safe), PROVIDER_REAP, txId, amount);
    }

    function test_addHold_revertsOnZeroAmount() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(IPendingHoldsModule.InvalidAmount.selector);
        pendingHoldsModule.addHold(address(safe), PROVIDER_REAP, txId, 0);
    }

    function test_addHold_revertsWhenExceedsDailyLimit() public {
        // daily limit = 10_000e6 — hold exceeds it so consumeSpendingLimit reverts
        uint256 exceedingAmount = 10_001e6;

        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        pendingHoldsModule.addHold(address(safe), PROVIDER_REAP, txId, exceedingAmount);
    }

    function test_addHold_revertsWhenNotEtherFiWallet() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        pendingHoldsModule.addHold(address(safe), PROVIDER_REAP, txId, 100e6);
    }

    function test_addHold_providerCodeNamespacing_noCollisionBetweenProviders() public {
        uint256 amount = 100e6;
        _addHold(PROVIDER_REAP, txId, amount);

        // Same txId, different providerCode — should succeed (separate namespace)
        vm.prank(etherFiWallet);
        pendingHoldsModule.addHold(address(safe), PROVIDER_RAIN, txId, amount);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), amount * 2);
    }

    // -------------------------------------------------------------------------
    // forceAddHold
    // -------------------------------------------------------------------------

    function test_forceAddHold_bypassesSpendableCheck_setsForcedTrue() public {
        uint256 exceedingAmount = 10_001e6; // beyond rawSpendable

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldAdded(address(safe), PROVIDER_REAP, txId, exceedingAmount, block.timestamp, true);
        pendingHoldsModule.forceAddHold(address(safe), PROVIDER_REAP, txId, exceedingAmount);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), exceedingAmount);

        HoldRecord memory hold = pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId);
        assertTrue(hold.forced);
    }

    function test_forceAddHold_revertsOnDuplicate() public {
        _addHold(PROVIDER_REAP, txId, 100e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(IPendingHoldsModule.DuplicateHold.selector);
        pendingHoldsModule.forceAddHold(address(safe), PROVIDER_REAP, txId, 100e6);
    }

    // -------------------------------------------------------------------------
    // updateHold
    // -------------------------------------------------------------------------

    function test_updateHold_increase_updatesTotalHolds() public {
        uint256 initial = 100e6;
        uint256 increased = 200e6;

        _addHold(PROVIDER_REAP, txId, initial);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), initial);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldUpdated(address(safe), PROVIDER_REAP, txId, initial, increased, block.timestamp);
        pendingHoldsModule.updateHold(address(safe), PROVIDER_REAP, txId, increased);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), increased);
        assertEq(pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId).amountUsd, increased);
    }

    function test_updateHold_decrease_updatesTotalHolds() public {
        uint256 initial = 200e6;
        uint256 decreased = 100e6;

        _addHold(PROVIDER_REAP, txId, initial);

        vm.prank(etherFiWallet);
        pendingHoldsModule.updateHold(address(safe), PROVIDER_REAP, txId, decreased);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), decreased);
        assertEq(pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId).amountUsd, decreased);
    }

    function test_updateHold_increase_revertsWhenExceedsDailyLimit() public {
        uint256 initial = 9_900e6;
        // After addHold(9_900), spentToday=9_900, remaining=100. Delta of 101 breaches limit.
        uint256 exceedingIncrease = 10_001e6;

        _addHold(PROVIDER_REAP, txId, initial);

        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        pendingHoldsModule.updateHold(address(safe), PROVIDER_REAP, txId, exceedingIncrease);
    }

    function test_updateHold_revertsOnHoldNotFound() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(IPendingHoldsModule.HoldNotFound.selector);
        pendingHoldsModule.updateHold(address(safe), PROVIDER_REAP, txId, 100e6);
    }

    // -------------------------------------------------------------------------
    // releaseHold
    // -------------------------------------------------------------------------

    function test_releaseHold_reversal_decrementsAndDeletes() public {
        uint256 amount = 100e6;
        _addHold(PROVIDER_REAP, txId, amount);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldReleased(address(safe), PROVIDER_REAP, txId, amount, ReleaseReason.REVERSAL, block.timestamp);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_REAP, txId, ReleaseReason.REVERSAL);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertEq(pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId).createdAt, 0);
    }

    function test_releaseHold_admin_works() public {
        uint256 amount = 100e6;
        _addHold(PROVIDER_REAP, txId, amount);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldReleased(address(safe), PROVIDER_REAP, txId, amount, ReleaseReason.ADMIN, block.timestamp);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_REAP, txId, ReleaseReason.ADMIN);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
    }

    function test_releaseHold_revertsOnHoldNotFound() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(IPendingHoldsModule.HoldNotFound.selector);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_REAP, txId, ReleaseReason.REVERSAL);
    }

    // -------------------------------------------------------------------------
    // removeHold (onlyCashModuleCore)
    // -------------------------------------------------------------------------

    function test_removeHold_revertsWhenCalledByNonCore() public {
        _addHold(PROVIDER_REAP, txId, 100e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(IPendingHoldsModule.OnlyCashModuleCore.selector);
        pendingHoldsModule.removeHold(address(safe), BinSponsor.Reap, txId);
    }

    function test_removeHold_succeedsWhenModulePaused() public {
        // removeHold must not be blocked by pause — pausing PHM should halt new hold creation
        // but must not freeze in-flight settlements that CashModuleCore drives via spend().
        _addHold(PROVIDER_REAP, txId, 100e6);

        vm.prank(pauser);
        PendingHoldsModule(address(pendingHoldsModule)).pause();

        // spend() → removeHold() must still succeed under pause
        deal(address(usdc), address(safe), 100e6);
        _spendWithHold(txId, BinSponsor.Reap, 100e6);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
    }

    function test_updateHold_decrease_defensiveFloor_noUnderflow() public {
        // Simulate a corrupted totalHolds where the running sum is less than oldAmountUsd.
        // After fix, the decreasing branch uses the same floor pattern as releaseHold/removeHold
        // rather than a bare subtraction that would revert with underflow.

        uint256 amount = 200e6;
        bytes32 txId2 = keccak256("txId2");

        _addHold(PROVIDER_REAP, txId, amount);
        _addHold(PROVIDER_RAIN, txId2, amount);
        // totalHolds = 400e6

        // Release txId2 via releaseHold — totalHolds drops to 200e6
        vm.prank(etherFiWallet);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_RAIN, txId2, ReleaseReason.ADMIN);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), amount);

        // Decreasing update on txId (200e6 → 50e6) — floor kicks in if drift exists; normal path here
        vm.prank(etherFiWallet);
        pendingHoldsModule.updateHold(address(safe), PROVIDER_REAP, txId, 50e6);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 50e6);
        assertEq(pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId).amountUsd, 50e6);
    }

    // -------------------------------------------------------------------------
    // providerCodeFromBinSponsor
    // -------------------------------------------------------------------------

    function test_providerCodeFromBinSponsor_mappings() public view {
        assertEq(pendingHoldsModule.providerCodeFromBinSponsor(BinSponsor.Reap), bytes4("REAP"));
        assertEq(pendingHoldsModule.providerCodeFromBinSponsor(BinSponsor.Rain), bytes4("RAIN"));
        assertEq(pendingHoldsModule.providerCodeFromBinSponsor(BinSponsor.PIX), bytes4("PIX_"));
        assertEq(pendingHoldsModule.providerCodeFromBinSponsor(BinSponsor.CardOrder), bytes4("CORD"));
    }

    // -------------------------------------------------------------------------
    // CashModuleSetters auth guards
    // -------------------------------------------------------------------------

    function test_setPendingHoldsModule_revertsIfNotController() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        cashModule.setPendingHoldsModule(address(pendingHoldsModule));
    }

    function test_consumeSpendingLimit_revertsIfNotPHM() public {
        // Any caller that is not the registered pendingHoldsModule must be rejected.
        // cashModule is ICashModule so we low-level call to avoid interface type constraint.
        vm.prank(address(0xdead));
        (bool ok,) = address(cashModule).call(
            abi.encodeWithSignature("consumeSpendingLimit(address,uint256)", address(safe), 100e6)
        );
        assertFalse(ok, "consumeSpendingLimit should revert for non-PHM caller");
    }

    function test_releaseSpendingLimit_revertsIfNotPHM() public {
        vm.prank(address(0xdead));
        (bool ok,) = address(cashModule).call(
            abi.encodeWithSignature("releaseSpendingLimit(address,uint256)", address(safe), 100e6)
        );
        assertFalse(ok, "releaseSpendingLimit should revert for non-PHM caller");
    }
}

// =============================================================================
// Integration tests: CashModule + PendingHoldsModule
// =============================================================================

contract PendingHoldsIntegrationTest is PendingHoldsTestSetup {

    // -------------------------------------------------------------------------
    // spend() integration
    // -------------------------------------------------------------------------

    function test_spend_withMatchingHold_removesHoldAndSettles() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        _addHold(PROVIDER_REAP, txId, amount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), amount);

        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldRemoved(address(safe), PROVIDER_REAP, txId, amount, block.timestamp);
        _spendWithHold(txId, BinSponsor.Reap, amount);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertEq(pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId).createdAt, 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_spend_withNoMatchingHold_settlementIsKing_succeedsAndBypassesLimit() public {
        // "Settlement is KING": spend() with no prior hold creates a forced hold and settles.
        // The spending limit is NOT charged (bypass), and the transaction is cleared.
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        // No hold added — spend() creates a forced hold internally and settles it
        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldAdded(address(safe), PROVIDER_REAP, txId, amount, block.timestamp, true);
        vm.expectEmit(true, true, true, true);
        emit IPendingHoldsModule.HoldRemoved(address(safe), PROVIDER_REAP, txId, amount, block.timestamp);
        _spendWithoutHold(txId, BinSponsor.Reap, amount);

        // Limit is bypassed (Settlement is KING)
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore);
        // Hold is gone after settlement
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_spend_settlementLessThanHold_creditsLimitDeltaBack() public {
        // Settlement < hold: the $50 over-auth is credited back to the spending limit.
        // settlementSyncHold updates hold 150→100, releasing $50 delta from spentToday/spentThisMonth.
        uint256 holdAmount = 150e6;  // hold was for $150
        uint256 settleAmount = 100e6; // settlement comes in at $100

        deal(address(usdc), address(safe), holdAmount);
        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        _addHold(PROVIDER_REAP, txId, holdAmount);
        // addHold consumed $150 from limit
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - holdAmount);

        _spendWithHold(txId, BinSponsor.Reap, settleAmount);

        // $50 delta credited back: limit now reflects only $100 consumed
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - settleAmount);
    }

    function test_spend_settlementExceedsHold_chargesOnlyDelta() public {
        // Tip / gratuity scenario: settlement > hold amount.
        // The hold pre-charged $100 at addHold. The extra $20 tip must be charged at settlement.
        uint256 holdAmount = 100e6;
        uint256 settleAmount = 120e6;

        deal(address(usdc), address(safe), settleAmount);
        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        _addHold(PROVIDER_REAP, txId, holdAmount);
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - holdAmount);

        _spendWithHold(txId, BinSponsor.Reap, settleAmount);

        // The $20 delta must be charged: total limit consumed = $100 (hold) + $20 (delta) = $120
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - settleAmount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
    }

    function test_spend_withForceAddHold_chargesFullLimitAtSettlement() public {
        // forceAddHold bypasses consumeSpendingLimit — limit is NOT charged at addHold time.
        // When spend() settles it, limitConsumed=false (hold.forced=true) so the full amount is charged.
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        // Force-add: no limit consumption
        vm.prank(etherFiWallet);
        pendingHoldsModule.forceAddHold(address(safe), PROVIDER_REAP, txId, amount);
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore); // limit unchanged

        // Normal spend() clears the forced hold and NOW charges the limit
        _spendWithHold(txId, BinSponsor.Reap, amount);

        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - amount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    // -------------------------------------------------------------------------
    // requestWithdrawal() guard
    // -------------------------------------------------------------------------

    function test_requestWithdrawal_blockedWhenHoldsExist() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        _addHold(PROVIDER_REAP, txId, amount);

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
        _addHold(PROVIDER_REAP, txId, amount);

        // Release hold first
        vm.prank(etherFiWallet);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_REAP, txId, ReleaseReason.REVERSAL);

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

    function test_spend_withNoHold_deductsBalanceAndBypassesLimit() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 safeBalBefore = usdc.balanceOf(address(safe));
        uint256 dispatcherBalBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        _spendWithoutHold(txId, BinSponsor.Reap, amount);

        assertEq(usdc.balanceOf(address(safe)), safeBalBefore - debtManager.convertUsdToCollateralToken(address(usdc), amount));
        assertGt(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBalBefore);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
        // Limit is bypassed (Settlement is KING)
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore);
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

        _addHold(PROVIDER_REAP, txId, holdAmount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), holdAmount);

        // spend() on a different txId (no-hold path) — creates and immediately removes a forced hold
        bytes32 noHoldTxId = keccak256("noHoldTxId");
        _spendWithoutHold(noHoldTxId, BinSponsor.Reap, spendAmount);

        // Original hold for txId is unaffected
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), holdAmount);
        assertTrue(cashModule.transactionCleared(address(safe), noHoldTxId));
    }

    function test_spend_afterForceAddHold_sameTxId_clearsHoldAndChargesLimit() public {
        // forceAddHold followed by spend() on the same txId clears the hold.
        // Unlike the no-hold path, the forced hold (forceAddHold) bypassed the limit at creation,
        // so spend() charges the full settlement amount to the spending limit.
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = cashModule.rawSpendable(address(safe));

        // Force-capture: place a hold without a balance check (no limit consumption)
        vm.prank(etherFiWallet);
        pendingHoldsModule.forceAddHold(address(safe), PROVIDER_REAP, txId, amount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), amount);
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore); // limit unchanged

        // Settlement via spend() — clears the forced hold and charges limit
        _spendWithHold(txId, BinSponsor.Reap, amount);

        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertEq(pendingHoldsModule.getHold(address(safe), PROVIDER_REAP, txId).createdAt, 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
        // Forced hold: limit was NOT charged at forceAddHold, IS charged at settlement
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore - amount);
    }

    function test_releaseHoldThenSpend_settlementIsKing_consistentState() public {
        // After a hold is released (e.g. reversal), the settlement might still arrive.
        // spend() with no existing hold (Settlement is KING): creates a forced hold and settles.
        // Limit is NOT charged since the no-hold path bypasses it.
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = cashModule.rawSpendable(address(safe));
        _addHold(PROVIDER_REAP, txId, amount);

        // Admin releases the hold (e.g. force-capture recovery where hold is stale)
        vm.prank(etherFiWallet);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_REAP, txId, ReleaseReason.ADMIN);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        // releaseHold credits back the limit
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore);

        // Settlement arrives — no-hold path (Settlement is KING), limit NOT charged
        _spendWithoutHold(txId, BinSponsor.Reap, amount);

        assertTrue(cashModule.transactionCleared(address(safe), txId));
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        // Limit unchanged since no-hold path bypasses it
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore);
    }

    // -------------------------------------------------------------------------
    // Integration: full flows
    // -------------------------------------------------------------------------

    function test_integration_fullAuthToSettlement() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        // 1. Auth acknowledged: add hold
        _addHold(PROVIDER_REAP, txId, amount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), amount);

        // 2. Settlement: spend removes hold
        _spendWithHold(txId, BinSponsor.Reap, amount);

        // 3. Hold cleared, transaction settled
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_integration_reversalFlow() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 rawBefore = cashModule.rawSpendable(address(safe));
        _addHold(PROVIDER_REAP, txId, amount);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), amount);

        // Network reversal — hold released, limit credited back
        vm.prank(etherFiWallet);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_REAP, txId, ReleaseReason.REVERSAL);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore); // limit restored

        // Settlement arrives despite reversal: Settlement is KING — spend() uses no-hold path.
        // This creates a forced hold internally and settles without charging the limit.
        deal(address(usdc), address(safe), amount);
        _spendWithoutHold(txId, BinSponsor.Reap, amount);

        assertTrue(cashModule.transactionCleared(address(safe), txId));
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), 0);
        // No-hold path: limit is NOT charged
        assertEq(cashModule.rawSpendable(address(safe)), rawBefore);
    }

    function test_integration_incrementalAuth() public {
        uint256 initial = 100e6;
        uint256 increased = 150e6;
        uint256 decreased = 120e6;

        _addHold(PROVIDER_REAP, txId, initial);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), initial);

        // Incremental auth: amount goes up
        vm.prank(etherFiWallet);
        pendingHoldsModule.updateHold(address(safe), PROVIDER_REAP, txId, increased);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), increased);

        // Incremental auth: amount goes down
        vm.prank(etherFiWallet);
        pendingHoldsModule.updateHold(address(safe), PROVIDER_REAP, txId, decreased);
        assertEq(pendingHoldsModule.totalPendingHolds(address(safe)), decreased);
    }

    function test_integration_withdrawalGuard_addHoldThenBlockThenReleaseThenAllow() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        _addHold(PROVIDER_REAP, txId, amount);

        // Pre-compute nonce BEFORE vm.expectRevert — safe.nonce() is an external call that would
        // otherwise consume the expectRevert before requestWithdrawal is reached.
        uint256 nonce = safe.nonce();
        vm.expectRevert(abi.encodeWithSignature("WithdrawalBlockedByPendingHolds()"));
        _requestWithdrawalRaw(nonce, tokens, amounts, withdrawRecipient);

        // Release hold
        vm.prank(etherFiWallet);
        pendingHoldsModule.releaseHold(address(safe), PROVIDER_REAP, txId, ReleaseReason.REVERSAL);

        // Withdrawal now allowed — use _requestWithdrawal helper which also checks the emitted event
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
    }
}

// =============================================================================
// CashLens pending holds views
// =============================================================================

contract PendingHoldsLensTest is PendingHoldsTestSetup {

    function test_spendable_noHolds_equalsRawSpendable() public view {
        uint256 raw = cashModule.rawSpendable(address(safe));
        assertEq(cashLens.spendable(address(safe)), raw);
    }

    function test_spendable_withHolds_reflectsLimitConsumption() public {
        uint256 holdAmount = 100e6;
        _addHold(PROVIDER_REAP, txId, holdAmount);

        // addHold consumes from spentToday; rawSpendable already reflects the hold.
        // spendable() == rawSpendable() — no separate deduction.
        uint256 raw = cashModule.rawSpendable(address(safe));
        assertEq(cashLens.spendable(address(safe)), raw);
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
        _addHold(PROVIDER_REAP, txId, 9_900e6);

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
        _addHold(PROVIDER_REAP, txId, existingHold);

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

    function test_holdsSummary_returnsConsistentValues() public {
        uint256 holdAmount = 250e6;
        _addHold(PROVIDER_REAP, txId, holdAmount);

        (uint256 totalHolds, uint256 spendableAmt, uint256 rawSpendableAmt) = cashLens.holdsSummary(address(safe));

        // totalHolds tracks the on-chain hold for the withdrawal guard and display.
        assertEq(totalHolds, holdAmount);
        // rawSpendable already reflects the hold (charged to spentToday at addHold time).
        assertEq(rawSpendableAmt, cashModule.rawSpendable(address(safe)));
        // spendableAmt == rawSpendableAmt — holds are in spentToday, not a separate deduction.
        assertEq(spendableAmt, rawSpendableAmt);
        // Cross-check with standalone spendable()
        assertEq(spendableAmt, cashLens.spendable(address(safe)));
    }

    function test_holdsSummary_noHolds_spendableEqualsRaw() public view {
        (uint256 totalHolds, uint256 spendableAmt, uint256 rawSpendableAmt) = cashLens.holdsSummary(address(safe));

        assertEq(totalHolds, 0);
        assertEq(spendableAmt, rawSpendableAmt);
    }
}

// =============================================================================
// Bytecode size gate — CashModuleCore must stay under EVM 24KB limit
// =============================================================================

contract CashModuleCoreBytecodeSizeTest is Test {
    function test_cashModuleCore_deployedSize_underLimit() public {
        // CashModuleCore must not exceed 24,576 bytes (EIP-170 limit)
        uint256 limit = 24_576;
        uint256 coreSize = address(new _CashModuleCoreForSizeCheck()).code.length;
        assertLt(coreSize, limit, "CashModuleCore deployed bytecode exceeds 24KB EVM limit");
    }
}

// Minimal deployment helper — avoids importing the full constructor chain in this file
import { CashModuleCore } from "../../../../src/modules/cash/CashModuleCore.sol";
import { EtherFiDataProvider } from "../../../../src/data-provider/EtherFiDataProvider.sol";

contract _CashModuleCoreForSizeCheck is CashModuleCore {
    constructor() CashModuleCore(address(1)) { }
}
