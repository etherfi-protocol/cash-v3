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
     * @notice Gets comprehensive cash data for a Safe
     * @dev Aggregates data from multiple sources including DebtManager and CashModule
     * @param safe Address of the EtherFi Safe
     * @param debtServiceTokenPreference Optional ordered array of borrow tokens for debit calculations.
     *                                   If empty, uses all available borrow tokens from DebtManager.
     * @return safeCashData Comprehensive data structure with collateral, borrows, limits, and more
     */
    function getSafeCashData(address safe, address[] memory debtServiceTokenPreference) external view returns (SafeCashData memory safeCashData);

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
