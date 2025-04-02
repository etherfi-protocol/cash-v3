// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SpendingLimit } from "../libraries/SpendingLimitLib.sol";
import { Mode, SafeTiers } from "./ICashModule.sol";

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
    function emitPendingCashbackClearedEvent(address safe, address recipient, address cashbackToken, uint256 cashbackAmount, uint256 cashbackInUsd) external;

    /**
     * @notice Emits the Cashback event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param spender Address of the spender
     * @param spendingInUsd USD value of the spending
     * @param cashbackToken Address of the cashback token
     * @param cashbackAmountToSafe Amount to the safe
     * @param cashbackInUsdToSafe USD value to the safe
     * @param cashbackAmountToSpender Amount to the spender
     * @param cashbackInUsdToSpender USD value to the spender
     * @param paid Whether the cashback was paid
     */
    function emitCashbackEvent(address safe, address spender, uint256 spendingInUsd, address cashbackToken, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) external;

    /**
     * @notice Emits the Spend event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param txId Transaction identifier
     * @param tokens Addresses of the tokens
     * @param amounts Amounts of tokens
     * @param amountsInUsd Amounts in USD value
     * @param totalUsdAmt Total amount in USD
     * @param mode Operational mode
     */
    function emitSpend(address safe, bytes32 txId, address[] memory tokens, uint256[] memory amounts, uint256[] memory amountsInUsd, uint256 totalUsdAmt, Mode mode) external;
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

    /**
     * @notice Emits the SafeTiersSet event
     * @dev Can only be called by the Cash Module
     * @param safes Array of safe addresses
     * @param safeTiers Array of tier configurations
     */
    function emitSetSafeTiers(address[] memory safes, SafeTiers[] memory safeTiers) external;
    
    /**
     * @notice Emits the TierCashbackPercentageSet event
     * @dev Can only be called by the Cash Module
     * @param safeTiers Array of tiers
     * @param cashbackPercentages Array of cashback percentages
     */
    function emitSetTierCashbackPercentage(SafeTiers[] memory safeTiers, uint256[] memory cashbackPercentages) external;
    
    /**
     * @notice Emits the CashbackSplitToSafeBpsSet event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param oldSplitInBps Previous split percentage
     * @param newSplitInBps New split percentage
     */
    function emitSetCashbackSplitToSafeBps(address safe, uint256 oldSplitInBps, uint256 newSplitInBps) external;
    
    /**
     * @notice Emits the DelaysSet event
     * @dev Can only be called by the Cash Module
     * @param withdrawalDelay Delay period for withdrawals
     * @param spendingLimitDelay Delay period for spending limit changes
     * @param modeDelay Delay period for mode changes
     */
    function emitSetDelays(uint64 withdrawalDelay, uint64 spendingLimitDelay, uint64 modeDelay) external;
}
