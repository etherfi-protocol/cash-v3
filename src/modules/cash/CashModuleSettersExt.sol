// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ICashModule, Mode, BinSponsor } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IPendingHoldsModule } from "../../interfaces/IPendingHoldsModule.sol";
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

    // -------------------------------------------------------------------------
    // Repayment (relocated from CashModuleSetters to free bytecode room)
    // -------------------------------------------------------------------------

    /**
     * @notice Repays borrowed tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses. Routed via fallback hops.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws OnlyBorrowToken if token is not a valid borrow token
     */
    function repay(address safe, address token, uint256 amountInUsd) public whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        IDebtManager debtManager = _getDebtManager();
        if (!_isBorrowToken(debtManager, token)) revert OnlyBorrowToken();
        _repay(safe, debtManager, token, amountInUsd);
    }

    /**
     * @dev Internal function to execute the repayment transaction
     * @custom:throws AmountZero if the converted amount is zero
     */
    function _repay(address safe, IDebtManager debtManager, address token, uint256 amountInUsd) internal {
        uint256 amount = IDebtManager(debtManager).convertUsdToCollateralToken(token, amountInUsd);
        if (amount == 0) revert AmountZero();
        _cancelWithdrawalRequestIfNecessary(safe, token, amount);

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = token;
        to[1] = address(debtManager);
        to[2] = token;

        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(debtManager), amount);
        data[1] = abi.encodeWithSelector(IDebtManager.repay.selector, safe, token, amount);
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, address(debtManager), 0);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        _getCashModuleStorage().cashEventEmitter.emitRepayDebtManager(safe, token, amount, amountInUsd);
    }

    // -------------------------------------------------------------------------
    // Under-funded settlement collection (C1)
    // -------------------------------------------------------------------------

    /**
     * @notice Collects the outstanding remainder of an under-funded settlement from the safe's balance.
     * @dev When spend() settled a transaction the safe could not fully cover, the unpaid remainder is
     *      parked in a forced "remaining" hold (see CashModuleCore._phmFinalize). This lets ops sweep
     *      that remainder once the safe is funded: it pays up to the outstanding remainder from `token`,
     *      reduces the hold, and removes it (unblocking withdrawals) once fully paid.
     *
     *      The spending limit is NOT charged again — the full settlement amount was already charged at
     *      the original spend(). Only operates on already-settled transactions (transactionCleared == true),
     *      which distinguishes a post-settlement debt from a pre-settlement forceAddHold hold.
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier (the original authorization/settlement id)
     * @param binSponsor Bin sponsor the settlement was made under
     * @param token Borrow token to collect the remainder from
     * @custom:throws InvalidInput if PHM unset, txId not yet settled, or no remainder outstanding
     * @custom:throws UnsupportedToken if token is not a borrow token
     * @custom:throws InsufficientBalance if the safe holds nothing collectable in token
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
        if (!_isBorrowToken($.debtManager, token)) revert UnsupportedToken();

        uint256 remaining = IPendingHoldsModule(phm).remainingHold(safe, binSponsor, txId);
        if (remaining == 0) revert InvalidInput();

        (uint256 payToken, uint256 paidUsd) = _collectAmounts($, safe, token, remaining);

        _cancelWithdrawalRequestIfNecessary(safe, token, payToken);
        _collectTransferAndEmit($, safe, binSponsor, txId, token, payToken, paidUsd);

        // Reduce or clear the hold. No limit charge — already charged at the original settlement.
        if (remaining - paidUsd == 0) IPendingHoldsModule(phm).removeHold(safe, binSponsor, txId);
        else IPendingHoldsModule(phm).settlementSetRemainingHold(safe, binSponsor, txId, remaining - paidUsd);

        $.debtManager.ensureHealth(safe);
    }

    /// @dev Computes how much of `remaining` (USD 1e6) can be collected from the safe's `token` balance.
    ///      Rounds USD down (favors the safe). Reverts if nothing meaningful is collectable.
    function _collectAmounts(CashModuleStorage storage $, address safe, address token, uint256 remaining)
        private
        view
        returns (uint256 payToken, uint256 paidUsd)
    {
        uint256 required = $.debtManager.convertUsdToCollateralToken(token, remaining);
        if (required == 0) revert AmountZero();
        uint256 available = IERC20(token).balanceOf(safe);
        if (available < required) {
            payToken = available;
            paidUsd = remaining * available / required; // round down — never over-credits the debt
        } else {
            payToken = required;
            paidUsd = remaining;
        }
        // Refuse a transfer that would move tokens without reducing the recorded debt (dust guard).
        if (paidUsd == 0) revert InsufficientBalance();
    }

    /// @dev Transfers the collected tokens to the settlement dispatcher and emits a Spend event.
    function _collectTransferAndEmit(
        CashModuleStorage storage $,
        address safe,
        BinSponsor binSponsor,
        bytes32 txId,
        address token,
        uint256 payToken,
        uint256 paidUsd
    ) private {
        // Single source of truth for the dispatcher mapping: CashModuleCore.getSettlementDispatcher.
        // Ext runs in Core's storage via delegatecall, so address(this) is the Core proxy.
        address dispatcher = ICashModule(address(this)).getSettlementDispatcher(binSponsor);

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = token;
        data[0] = abi.encodeWithSelector(IERC20.transfer.selector, dispatcher, payToken);
        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](1), data);

        uint256[] memory tokenAmounts = new uint256[](1);
        uint256[] memory usdAmounts = new uint256[](1);
        tokenAmounts[0] = payToken;
        usdAmounts[0] = paidUsd;
        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, to, tokenAmounts, usdAmounts, paidUsd, Mode.Debit);
    }
}
