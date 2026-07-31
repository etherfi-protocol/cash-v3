// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, HoldAction, HoldRecord } from "../../interfaces/ICashModule.sol";
import { CashHoldsLib } from "../../libraries/CashHoldsLib.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashModuleHolds
 * @author ether.fi
 * @notice The CashModule's card-hold entrypoints: recording, re-authorizing, releasing and collecting on
 *         the holds that track authorized-but-unsettled card transactions.
 *
 * @dev Part of the CashModule, not a separate contract in its own right. Reached through the module's
 *      fallback chain — CashModuleCore.fallback() delegatecalls CashModuleSetters, and
 *      CashModuleSetters.fallback() delegatecalls here — so every function runs in the module's own
 *      storage with the original msg.sender preserved. It exists only because Core and Setters are both at
 *      the EIP-170 24KB ceiling; it declares no storage of its own and shares the module's layout through
 *      CashModuleStorageContract.
 *
 *      These are thin entrypoints: access control here, accounting in CashHoldsLib.
 */
contract CashModuleHolds is CashModuleStorageContract {
    using SpendingLimitLib for SpendingLimit;

    constructor(address _etherFiDataProvider) CashModuleStorageContract(_etherFiDataProvider) {
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Card-transaction holds
    // -------------------------------------------------------------------------

    /**
     * @notice Applies one change to a card transaction's hold
     * @dev One entrypoint for the whole authorization lifecycle — record an authorization, record one the
     *      provider already committed us to, re-authorize, or release — so the module carries one
     *      access-control stack instead of four. See HoldAction for what each does; CashHoldsLib.applyHold
     *      owns the accounting. `amountUsd` is ignored by RELEASE.
     * @param safe Address of the EtherFi Safe
     * @param binSponsor Bin sponsor of the card transaction; it namespaces the provider's transaction id
     * @param txId Provider transaction identifier
     * @param amountUsd The amount the transaction owes after this change, in USD (1e6)
     * @param action Which change to apply
     */
    function applyHold(address safe, BinSponsor binSponsor, bytes32 txId, uint256 amountUsd, HoldAction action) external whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashHoldsLib.applyHold(_getCashModuleStorage(), safe, binSponsor, txId, amountUsd, action);
    }

    /**
     * @notice Collects what an under-funded settlement still owes, once the safe has been funded
     * @dev The unpaid part of a settlement stays as the transaction's hold and keeps withdrawals blocked.
     *      This sweeps it through the same debit path a settlement uses and clears the hold once fully
     *      paid. The spending limit is not charged again — the whole settlement was charged when it first
     *      settled.
     * @param safe Address of the EtherFi Safe
     * @param binSponsor Bin sponsor the settlement was made under
     * @param txId Provider transaction identifier
     * @param token Token to collect from
     */
    function collectRemaining(address safe, BinSponsor binSponsor, bytes32 txId, address token) external whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashHoldsLib.collectRemaining(_getCashModuleStorage(), etherFiDataProvider, safe, binSponsor, txId, token);
    }

    /**
     * @notice A safe's card-hold state: this transaction's hold, the safe's total held, and what it can
     *         still spend — all in one call, which is what a decline investigation actually needs
     * @dev `hold` is a zero record when the transaction has no hold. `totalHeldUsd` is the figure that
     *      blocks withdrawals. `spendableUsd` is min(remaining daily, remaining monthly): an authorized
     *      transaction is charged to the limit when its hold is recorded, so this already accounts for
     *      money in flight — do NOT subtract totalHeldUsd from it as well.
     * @param safe Address of the EtherFi Safe
     * @param binSponsor Bin sponsor of the card transaction to look up
     * @param txId Provider transaction identifier to look up
     */
    function holdsOf(address safe, BinSponsor binSponsor, bytes32 txId) external view returns (HoldRecord memory hold, uint256 totalHeldUsd, uint256 spendableUsd) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        return ($.holds[CashHoldsLib.holdKey(safe, binSponsor, txId)], $.totalHolds[safe], $.safeCashConfig[safe].spendingLimit.maxCanSpend());
    }

    /**
     * @notice Turns partial settlement on or off
     * @dev When on, a settlement the safe cannot fully cover pays what it can and leaves the rest as the
     *      transaction's hold for ops to sweep with collectRemaining. When off — the default, and the
     *      behavior before holds existed — such a settlement reverts. Off until the backend is ready to
     *      handle the remainder, so the contract can ship ahead of it.
     * @param enabled Whether an under-funded settlement may settle short
     */
    function setPartialSettlementEnabled(bool enabled) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();
        _getCashModuleStorage().partialSettlementEnabled = enabled;
    }

    /// @notice Whether an under-funded settlement may settle short and leave the rest as a hold
    function partialSettlementEnabled() external view returns (bool) {
        return _getCashModuleStorage().partialSettlementEnabled;
    }

}
