// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, HoldAction, HoldRecord } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { CashLendLib } from "../modules/cash/CashLendLib.sol";
import { CashModuleStorageContract } from "../modules/cash/CashModuleStorageContract.sol";
import { SpendingLimit, SpendingLimitLib } from "./SpendingLimitLib.sol";

/**
 * @title CashHoldsLib
 * @notice The CashModule's card-hold registry: the on-chain record of authorized-but-unsettled card
 *         transactions, and the spending-limit accounting that goes with it.
 * @dev Deployed once and linked into CashModuleCore and CashModuleSetters, so this logic does not count
 *      against either implementation's EIP-170 runtime code-size limit. Every function is called via
 *      delegatecall and therefore runs in the CashModule's storage context, which is the whole point:
 *      holds and the spending limit live in the same storage, so a hold can charge the limit with a plain
 *      write instead of a cross-contract call back into the module.
 *
 *      One accounting rule covers every path. A hold stores two numbers: `amountUsd`, what the
 *      transaction currently owes, and `chargedUsd`, how much of that is already reflected in the safe's
 *      daily/monthly spending limit. Whenever either changes, `reconcileLimit(chargedUsd, newOwed)` makes
 *      the limit reflect the new figure — charging the increase, crediting back the decrease. That single
 *      rule replaces the per-path special cases:
 *        - authorized hold      → charged == amount, so settling at the same amount is a no-op
 *        - settlement above it  → the tip is charged at settlement
 *        - settlement below it  → the unused authorization is credited back
 *        - no hold at all       → charged is 0, so the full settlement is charged ("settlement is king")
 *        - operator-forced hold → charged is 0 until it settles
 *        - unpaid remainder     → charged == remainder, so collecting it later cannot charge twice
 *
 *      Hold keys are namespaced by bin sponsor — keccak256(safe, binSponsor, txId) — so the same
 *      provider transaction id cannot collide across Rain / Reap / PIX. Every caller passes the
 *      BinSponsor it already has in scope, so an authorization and its settlement cannot key differently.
 *
 *      `amountUsd` is the existence flag: holds are never stored with a zero amount, so
 *      `amountUsd == 0` means "no hold".
 * @author ether.fi
 */
library CashHoldsLib {
    using SpendingLimitLib for SpendingLimit;

    /// @notice Thrown when a hold write targets a transaction with no hold
    error HoldNotFound();
    /// @notice Thrown when adding a hold for a transaction that already has one
    error DuplicateHold();
    /// @notice Thrown when a hold amount argument is zero
    error InvalidAmount();
    /// @notice Thrown when a collection targets a transaction that has not settled or owes nothing
    error InvalidInput();
    /// @notice Thrown when the safe has nothing collectable in the requested token
    error InsufficientBalance();
    /// @notice Thrown when a per-hold amount exceeds the running total for the safe, i.e. the running sum
    ///         has drifted from the sum of the individual holds. Surfaced loudly rather than silently
    ///         floored, because that sum is what blocks withdrawals.
    error TotalHoldsUnderflow();

    /// @dev The hold key for a card transaction. The bin sponsor namespaces the provider's transaction id.
    function holdKey(address safe, BinSponsor binSponsor, bytes32 txId) internal pure returns (bytes32) {
        return keccak256(abi.encode(safe, binSponsor, txId));
    }

    /**
     * @notice Applies one change to a card transaction's hold
     * @dev A single entrypoint for the whole authorization lifecycle, so the module carries one access-control
     *      stack instead of four. `amountUsd` is ignored by RELEASE.
     *
     *      AUTHORIZE — the card network authorized a swipe. Records what it owes and charges that to the
     *        spending limit right away, so the limit reflects committed money and the same funds cannot be
     *        authorized twice.
     *      FORCE_AUTHORIZE — the provider has already committed us to the transaction. Records what it owes
     *        WITHOUT charging the limit, because refusing the hold would not undo the obligation; the limit is
     *        charged when it settles instead.
     *      REAUTHORIZE — an incremental authorization changed what it owes. The limit follows, but only for a
     *        hold that was charged in the first place.
     *      RELEASE — it will never settle (a network reversal, or an operator clearing a stuck
     *        authorization). Drops the hold and credits its charge back. Moves no funds.
     * @custom:throws DuplicateHold if an AUTHORIZE / FORCE_AUTHORIZE targets a transaction that already has a hold
     * @custom:throws HoldNotFound if a REAUTHORIZE / RELEASE targets a transaction with no hold
     * @custom:throws InvalidAmount if amountUsd is zero on anything but a RELEASE
     * @custom:throws ExceededDailySpendingLimit / ExceededMonthlySpendingLimit if the charge breaches the limit
     */
    function applyHold(CashModuleStorageContract.CashModuleStorage storage $, address safe, BinSponsor binSponsor, bytes32 txId, uint256 amountUsd, HoldAction action) external {
        if (action == HoldAction.RELEASE) {
            _release($, safe, binSponsor, txId);
            return;
        }
        if (amountUsd == 0) revert InvalidAmount();

        bytes32 key = holdKey(safe, binSponsor, txId);
        HoldRecord storage record = $.holds[key];
        uint256 oldAmountUsd = record.amountUsd;

        if (action == HoldAction.REAUTHORIZE) {
            if (oldAmountUsd == 0) revert HoldNotFound();
            // A hold that was never charged (FORCE_AUTHORIZE) stays uncharged until it settles.
            uint256 newChargedUsd = record.chargedUsd == 0 ? 0 : amountUsd;
            _reconcile($, safe, record.chargedUsd, newChargedUsd);
            _replaceTotalHolds($, safe, oldAmountUsd, amountUsd);
            record.amountUsd = amountUsd;
            record.chargedUsd = newChargedUsd;
            $.cashEventEmitter.emitHoldUpdated(safe, binSponsor, txId, oldAmountUsd, amountUsd);
            return;
        }

        if (oldAmountUsd != 0) revert DuplicateHold();
        uint256 chargedUsd = action == HoldAction.AUTHORIZE ? amountUsd : 0;
        _reconcile($, safe, 0, chargedUsd);
        record.amountUsd = amountUsd;
        record.chargedUsd = chargedUsd;
        record.createdAt = uint40(block.timestamp);
        $.totalHolds[safe] += amountUsd;
        $.cashEventEmitter.emitHoldAdded(safe, binSponsor, txId, amountUsd, chargedUsd);
    }

    /// @dev Drops a hold and credits its charge back to the spending limit.
    function _release(CashModuleStorageContract.CashModuleStorage storage $, address safe, BinSponsor binSponsor, bytes32 txId) private {
        bytes32 key = holdKey(safe, binSponsor, txId);
        HoldRecord storage record = $.holds[key];
        uint256 amountUsd = record.amountUsd;
        if (amountUsd == 0) revert HoldNotFound();

        // Nothing is owed any more, so the limit should reflect nothing for this transaction.
        _reconcile($, safe, record.chargedUsd, 0);
        _replaceTotalHolds($, safe, amountUsd, 0);
        delete $.holds[key];

        $.cashEventEmitter.emitHoldReleased(safe, binSponsor, txId, amountUsd);
    }

    /**
     * @notice Reconciles a transaction's hold against its actual settlement
     * @dev The single settlement primitive, called once per settlement after the funds have moved — by
     *      spend() for a card settlement, and by collectRemaining() when ops sweeps an unpaid remainder.
     *      It makes the spending limit reflect `owedUsd`, then either clears the hold (fully paid) or
     *      leaves the unpaid remainder as the hold, marked as already charged so sweeping it later cannot
     *      charge the limit a second time. A settlement with no hold is honored and charged in full.
     * @param owedUsd What the settlement says the transaction owes
     * @param paidUsd What the safe actually paid, at most owedUsd
     * @custom:throws ExceededDailySpendingLimit / ExceededMonthlySpendingLimit if owedUsd exceeds what the
     *                limit has left beyond what this transaction was already charged
     */
    function settle(CashModuleStorageContract.CashModuleStorage storage $, address safe, BinSponsor binSponsor, bytes32 txId, uint256 owedUsd, uint256 paidUsd) public {
        bytes32 key = holdKey(safe, binSponsor, txId);
        HoldRecord storage record = $.holds[key];
        uint256 heldUsd = record.amountUsd;

        _reconcile($, safe, heldUsd == 0 ? 0 : record.chargedUsd, owedUsd);

        uint256 remainingUsd = owedUsd - paidUsd;
        if (remainingUsd == 0) {
            if (heldUsd != 0) {
                _replaceTotalHolds($, safe, heldUsd, 0);
                delete $.holds[key];
            }
        } else {
            // The remainder is outstanding debt that keeps blocking withdrawals until ops sweeps it. It is
            // recorded as charged because the limit above already accounts for the whole settlement.
            _replaceTotalHolds($, safe, heldUsd, remainingUsd);
            record.amountUsd = remainingUsd;
            record.chargedUsd = remainingUsd;
            if (heldUsd == 0) record.createdAt = uint40(block.timestamp);
        }

        $.cashEventEmitter.emitHoldSettled(safe, binSponsor, txId, owedUsd, paidUsd, remainingUsd);
    }

    /**
     * @notice Collects what an under-funded settlement still owes, once the safe has been funded
     * @dev The unpaid part of a settlement stays as the transaction's hold and keeps withdrawals blocked.
     *      This sweeps it through the same debit path a settlement uses — loose balance first, then the
     *      Aave-supplied balance — and clears the hold once fully paid. The spending limit is not charged
     *      again: settle() below sees the remainder already marked as charged.
     * @param token Token to collect from
     * @custom:throws InvalidInput if the transaction has not settled yet, or owes nothing
     * @custom:throws InsufficientBalance if the safe has nothing collectable in the token
     */
    function collectRemaining(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, BinSponsor binSponsor, bytes32 txId, address token) external {
        // Must be a settled transaction's unpaid remainder, not an authorization still awaiting settlement.
        if (!$.safeCashConfig[safe].transactionCleared[txId]) revert InvalidInput();

        uint256 owed = $.holds[holdKey(safe, binSponsor, txId)].amountUsd;
        if (owed == 0) revert InvalidInput();

        address[] memory tokens = new address[](1);
        uint256[] memory amountsInUsd = new uint256[](1);
        tokens[0] = token;
        amountsInUsd[0] = owed;

        uint256 paid = CashLendLib.spendDebit($, dataProvider, safe, txId, binSponsor, tokens, amountsInUsd);
        // Refuse a sweep that moves nothing, so ops gets a clear signal instead of an unchanged hold.
        if (paid == 0) revert InsufficientBalance();

        settle($, safe, binSponsor, txId, owed, paid);
    }

    /// @notice What a transaction still owes on-chain, in USD (1e6); zero when it has no hold
    function remainingHold(CashModuleStorageContract.CashModuleStorage storage $, address safe, BinSponsor binSponsor, bytes32 txId) internal view returns (uint256) {
        return $.holds[holdKey(safe, binSponsor, txId)].amountUsd;
    }

    /// @dev Makes the safe's spending limit reflect `newCharged` where it currently reflects `oldCharged`.
    function _reconcile(CashModuleStorageContract.CashModuleStorage storage $, address safe, uint256 oldCharged, uint256 newCharged) private {
        $.safeCashConfig[safe].spendingLimit.reconcileLimit(oldCharged, newCharged);
    }

    /**
     * @dev Replaces `oldAmount` with `newAmount` in the safe's running hold total (pass 0 to remove).
     *      `oldAmount` is always read from the very hold being changed and every increment paired its
     *      stored amount, so oldAmount <= total is an invariant. Flooring a break silently would corrupt
     *      the sum that blocks withdrawals, so it reverts instead.
     */
    function _replaceTotalHolds(CashModuleStorageContract.CashModuleStorage storage $, address safe, uint256 oldAmount, uint256 newAmount) private {
        uint256 current = $.totalHolds[safe];
        if (oldAmount > current) revert TotalHoldsUnderflow();
        $.totalHolds[safe] = current - oldAmount + newAmount;
    }
}
