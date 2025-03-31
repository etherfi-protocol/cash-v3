// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCashData, SafeData } from "./ICashModule.sol";
import { IDebtManager } from "./IDebtManager.sol";

interface ICashLens {
    /**
     * @notice Checks if a spending transaction can be executed
     * @dev Simulates the spending process and checks for potential issues
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param token Address of the token to spend
     * @param amountInUsd Amount to spend in USD
     * @return canSpend Boolean indicating if the spending is allowed
     * @return message Error message if spending is not allowed
     */
    function canSpend(address safe, bytes32 txId, address token, uint256 amountInUsd) external view returns (bool, string memory);

    /**
     * @notice Calculates the maximum amount that can be spent in both credit and debit modes
     * @dev Performs separate calculations for credit and debit modes
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to spend
     * @return returnAmtInCreditModeUsd Maximum amount that can be spent in credit mode (USD)
     * @return returnAmtInDebitModeUsd Maximum amount that can be spent in debit mode (USD)
     * @return spendingLimitAllowance Remaining spending limit allowance
     */
    function maxCanSpend(address safe, address token) external view returns (uint256 returnAmtInCreditModeUsd, uint256 returnAmtInDebitModeUsd, uint256 spendingLimitAllowance);

    /**
     * @notice Gets comprehensive cash data for a Safe
     * @dev Aggregates data from multiple sources including DebtManager and CashModule
     * @param safe Address of the EtherFi Safe
     * @return safeCashData Comprehensive data structure with collateral, borrows, limits, and more
     */
    function getSafeCashData(address safe) external view returns (SafeCashData memory safeCashData);

    /**
     * @notice Gets the pending withdrawal amount for a token
     * @dev Searches through the withdrawal request tokens array for the specified token
     * @param safe Address of the safe
     * @param token Address of the token to check
     * @return Amount of tokens pending withdrawal
     */
    function getPendingWithdrawalAmount(address safe, address token) external view returns (uint256);

    function getUserCollateralForToken(address safe, address token) external view returns (uint256);

    function getUserTotalCollateral(address safe) external view returns (IDebtManager.TokenData[] memory);
}
