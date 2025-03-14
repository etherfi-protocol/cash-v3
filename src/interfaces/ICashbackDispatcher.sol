// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICashbackDispatcher
 * @notice Interface for the CashbackDispatcher contract
 */
interface ICashbackDispatcher {
    /**
     * @notice Function to fetch the admin role
     * @return CASHBACK_DISPATCHER_ADMIN_ROLE
     */
    function CASHBACK_DISPATCHER_ADMIN_ROLE() external view returns (bytes32);

    /**
     * @notice Convert a USD amount to the equivalent amount in cashback token
     * @param cashbackInUsd The amount in USD to convert
     * @return The equivalent amount in cashback token
     */
    function convertUsdToCashbackToken(uint256 cashbackInUsd) external view returns (uint256);

    /**
     * @notice Calculate the cashback amount based on the spent amount and cashback percentage
     * @param cashbackPercentageInBps The cashback percentage in basis points
     * @param spentAmountInUsd The amount spent in USD
     * @return The cashback amount in cashback token and USD
     */
    function getCashbackAmount(uint256 cashbackPercentageInBps, uint256 spentAmountInUsd) external view returns (uint256, uint256);

    /**
     * @notice Process cashback to a safe and a spender
     * @param safe The address of the safe
     * @param spender The address of the spender
     * @param spentAmountInUsd The amount spent in USD
     * @param cashbackPercentageInBps The cashback percentage in basis points
     * @param cashbackSplitToSafePercentage The percentage of cashback to send to the safe
     * @return token The address of the cashback token
     * @return cashbackAmountToSafe The amount of cashback token sent to the safe
     * @return cashbackInUsdToSafe The USD value of cashback sent to the safe
     * @return cashbackAmountToSpender The amount of cashback token sent to the spender
     * @return cashbackInUsdToSpender The USD value of cashback sent to the spender
     * @return paid Whether the cashback was paid successfully
     */
    function cashback(address safe, address spender, uint256 spentAmountInUsd, uint256 cashbackPercentageInBps, uint256 cashbackSplitToSafePercentage) external returns (address token, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid);

    /**
     * @notice Clear pending cashback for an account
     * @param account The address of the account
     * @return The cashback token address, the amount of cashback, and whether it was paid
     */
    function clearPendingCashback(address account) external returns (address, uint256, bool);

    /**
     * @notice Set the Cash Module address
     * @param _cashModule The address of the new Cash Module
     */
    function setCashModule(address _cashModule) external;

    /**
     * @notice Set the Price Provider address
     * @param _priceProvider The address of the new Price Provider
     */
    function setPriceProvider(address _priceProvider) external;

    /**
     * @notice Set the Cashback Token address
     * @param _token The address of the new Cashback Token
     */
    function setCashbackToken(address _token) external;

    /**
     * @notice Withdraw funds from the contract
     * @param token The address of the token to withdraw (address(0) for ETH)
     * @param recipient The address to receive the withdrawn funds
     * @param amount The amount to withdraw (0 for all available balance)
     */
    function withdrawFunds(address token, address recipient, uint256 amount) external;
}
