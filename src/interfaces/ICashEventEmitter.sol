// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SpendingLimit} from "../libraries/SpendingLimitLib.sol";
import {Mode, SafeTiers} from "./ICashModule.sol";

/**
 * @title ICashEventEmitter
 * @notice Interface for the CashEventEmitter contract that emits events for the Cash Module
 */
interface ICashEventEmitter {
    /**
     * @notice Emits an event when pending cashback is cleared
     * @param cashbackToken Address of the cashback token
     * @param cashbackAmount Amount of cashback token cleared
     * @param cashbackInUsd USD value of the cashback
     */
    function emitPendingCashbackClearedEvent(address safe, address cashbackToken, uint256 cashbackAmount, uint256 cashbackInUsd) external;

    function emitCashbackEvent(address safe, address spender, uint256 spendingInUsd, address cashbackToken, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) external;

    /**
     * @notice Emits an event for a spending transaction
     * @param token Address of the token spent
     * @param amount Amount of token spent
     * @param amountInUsd USD value of the amount spent
     * @param mode Mode used for the spending (Debit or Credit)
     */
    function emitSpend(address safe, address token, uint256 amount, uint256 amountInUsd, Mode mode) external;

    /**
     * @notice Emits an event when the mode is changed
     * @param prevMode Previous mode
     * @param newMode New mode
     * @param incomingModeStartTime Timestamp when the new mode becomes effective
     */
    function emitSetMode(address safe, Mode prevMode, Mode newMode, uint256 incomingModeStartTime) external;

    /**
     * @notice Emits an event when a withdrawal is requested
     * @param tokens Array of token addresses to withdraw
     * @param amounts Array of token amounts to withdraw
     * @param recipient Address to receive the withdrawn tokens
     * @param finalizeTimestamp Timestamp when the withdrawal can be finalized
     */
    function emitWithdrawalRequested(address safe, address[] memory tokens, uint256[] memory amounts, address recipient, uint256 finalizeTimestamp) external;

    /**
     * @notice Emits an event when a withdrawal amount is updated
     * @param token Address of the token
     * @param amount Updated withdrawal amount
     */
    function emitWithdrawalAmountUpdated(address safe, address token, uint256 amount) external;

    /**
     * @notice Emits an event when a withdrawal is cancelled
     * @param tokens Array of token addresses that were to be withdrawn
     * @param amounts Array of token amounts that were to be withdrawn
     * @param recipient Address that was to receive the withdrawn tokens
     */
    function emitWithdrawalCancelled(address safe, address[] memory tokens, uint256[] memory amounts, address recipient) external;

    /**
     * @notice Emits an event when a withdrawal is processed
     * @param tokens Array of token addresses withdrawn
     * @param amounts Array of token amounts withdrawn
     * @param recipient Address receiving the withdrawn tokens
     */
    function emitWithdrawalProcessed(address safe, address[] memory tokens, uint256[] memory amounts, address recipient) external;

    /**
     * @notice Emits an event when tokens are transferred for spending
     * @param token Address of the token transferred
     * @param amount Amount of token transferred
     */
    function emitTransferForSpending(address safe, address token, uint256 amount) external;

    /**
     * @notice Emits an event when tokens are borrowed from the debt manager
     * @param token Address of the token borrowed
     * @param amount Amount of token borrowed
     */
    function emitBorrowFromDebtManager(address safe, address token, uint256 amount) external;

    /**
     * @notice Emits an event when a debt is repaid to the debt manager
     * @param token Address of the token repaid
     * @param amount Amount of token repaid
     * @param amountInUsd USD value of the amount repaid
     */
    function emitRepayDebtManager(address safe, address token, uint256 amount, uint256 amountInUsd) external;

    /**
     * @notice Emits an event when spending limits are changed
     * @param oldLimit Previous spending limit
     * @param newLimit New spending limit
     */
    function emitSpendingLimitChanged(address safe, SpendingLimit memory oldLimit, SpendingLimit memory newLimit) external;

    function emitSetSafeTiers(address[] memory safes, SafeTiers[] memory safeTiers) external;
    function emitSetTierCashbackPercentage(SafeTiers[] memory safeTiers, uint256[] memory cashbackPercentages) external;
    function emitSetCashbackSplitToSafeBps(address safe, uint256 oldSplitInBps, uint256 newSplitInBps) external;
    function emitSetDelays(uint64 withdrawalDelay, uint64 spendingLimitDelay, uint64 modeDelay) external;
    function emitConfigureWithdrawRecipients(address safe, address[] calldata withdrawRecipients, bool[] calldata shouldWhitelist) external;
}