// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor } from "../../interfaces/ICashModule.sol";
import { IPendingHoldsModule } from "../../interfaces/IPendingHoldsModule.sol";
import { CashLendLib } from "./CashLendLib.sol";
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashModuleSettersExt
 * @author ether.fi
 * @notice Second overflow implementation for the Cash Module. Reached via a fallback hop:
 *         CashModuleCore.fallback() → delegatecall CashModuleSetters → CashModuleSetters.fallback()
 *         → delegatecall CashModuleSettersExt. Every hop is a delegatecall, so all functions here run
 *         in Core's storage context with the original msg.sender preserved.
 *
 * @dev Exists purely to keep CashModuleCore and CashModuleSetters under the EIP-170 24KB bytecode
 *      limit. Functions are placed here when neither Core nor Setters has room. This contract shares
 *      the exact storage layout of Core/Setters via CashModuleStorageContract and must NEVER declare
 *      its own state variables outside that layout.
 */
contract CashModuleSettersExt is CashModuleStorageContract {
    constructor(address _etherFiDataProvider) CashModuleStorageContract(_etherFiDataProvider) {
        _disableInitializers();
    }

    /**
     * @notice Collects the outstanding remainder of an under-funded settlement from the safe.
     * @dev When spend() settled a transaction the safe could not fully cover, the unpaid remainder is
     *      parked in a forced "remaining" hold (see CashModuleCore._phmFinalize). This lets ops sweep
     *      that remainder once the safe is funded: it settles up to the outstanding remainder from
     *      `token` through the same debit path a spend uses (so it is engine-aware — loose balance
     *      first, then the Aave-supplied balance), reduces the hold, and removes it once fully paid,
     *      which unblocks withdrawals.
     *
     *      The spending limit is NOT charged again — the full settlement amount was already charged at
     *      the original spend(). Only operates on already-settled transactions (transactionCleared ==
     *      true), which distinguishes a post-settlement debt from a pre-settlement forceAddHold hold.
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier (the original authorization/settlement id)
     * @param binSponsor Bin sponsor the settlement was made under
     * @param token Token to collect the remainder from
     * @custom:throws InvalidInput if the holds registry is unset, the txId is not yet settled, or no
     *                remainder is outstanding
     * @custom:throws InsufficientBalance if the safe has nothing collectable in `token`
     */
    function collectRemaining(address safe, bytes32 txId, BinSponsor binSponsor, address token)
        external
        whenNotPaused
        nonReentrant
        onlyEtherFiWallet
        onlyEtherFiSafe(safe)
    {
        CashModuleStorage storage $ = _getCashModuleStorage();
        address phm = $.pendingHoldsModule;
        if (phm == address(0)) revert InvalidInput();
        // Must be a post-settlement debt, not a pre-settlement forceAddHold hold awaiting spend().
        if (!$.safeCashConfig[safe].transactionCleared[txId]) revert InvalidInput();

        uint256 remaining = IPendingHoldsModule(phm).remainingHold(safe, binSponsor, txId);
        if (remaining == 0) revert InvalidInput();

        address[] memory tokens = new address[](1);
        uint256[] memory amountsInUsd = new uint256[](1);
        tokens[0] = token;
        amountsInUsd[0] = remaining;

        // Same sourcing, transfer and Spend event as a debit settlement, with partial settlement allowed:
        // the hold keeps carrying whatever this sweep could not cover.
        uint256 paidUsd = CashLendLib.spendDebit($, etherFiDataProvider, safe, txId, binSponsor, tokens, amountsInUsd);
        // Refuse a no-op sweep so ops gets a clear signal instead of a hold that never moves.
        if (paidUsd == 0) revert InsufficientBalance();

        // Reduce or clear the hold. No limit charge — already charged at the original settlement.
        if (paidUsd >= remaining) IPendingHoldsModule(phm).removeHold(safe, binSponsor, txId);
        else IPendingHoldsModule(phm).settlementSetRemainingHold(safe, binSponsor, txId, remaining - paidUsd);
    }
}
