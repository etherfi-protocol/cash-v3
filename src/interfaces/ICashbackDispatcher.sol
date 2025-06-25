// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICashbackDispatcher
 * @notice Interface for the CashbackDispatcher contract
 */
interface ICashbackDispatcher {
    /**
     * @notice Thrown when the price of the cashback token is not configured in the price provider
     */
    error CashbackTokenPriceNotConfigured();
    
    /**
     * @notice Thrown when a zero or invalid address is provided
     */
    error InvalidValue();
    
    /**
     * @notice Thrown when an operation requires an ether.fi safe but account is not one
     */
    error OnlyEtherFiSafe();
    
    /**
     * @notice Thrown when attempting to withdraw zero tokens or ETH
     */
    error CannotWithdrawZeroAmount();
    
    /**
     * @notice Thrown when a withdrawal of funds fails
     */
    error WithdrawFundsFailed();
    
    /**
     * @notice Thrown when a function is called by an account other than the Cash Module
     */
    error OnlyCashModule();
    
    /**
     * @notice Thrown when invalid input parameters are provided
     */
    error InvalidInput();
    
    /**
     * @notice Thrown when the cashback token is not supported
     */
    error InvalidCashbackToken();

    /**
     * @notice Function to fetch the admin role
     * @return CASHBACK_DISPATCHER_ADMIN_ROLE
     */
    function CASHBACK_DISPATCHER_ADMIN_ROLE() external view returns (bytes32);

    /**
     * @notice Returns true if the token is a whitelisted cashback token, false otherwise
     * @param token Address of the token
     * @return Returns true if the token is a whitelisted cashback token, false otherwise
     */
    function isCashbackToken(address token) external view returns (bool);

    /**
     * @notice Convert a USD amount to the equivalent amount in cashback token
     * @param cashbackInUsd The amount in USD to convert
     * @return The equivalent amount in cashback token
     */
    function convertUsdToCashbackToken(uint256 cashbackInUsd) external view returns (uint256);

    /**
     * @notice Process cashback to a recipient
     * @param recipient The address of the recipient
     * @param token The address of the cashback token
     * @param amountInUsd The amount of cashback tokens in USD to be paid out
     * @return cashbackAmountInToken The amount of cashback token sent to the recipient
     * @return paid Whether the cashback was paid successfully
     */
    function cashback(address recipient, address token, uint256 amountInUsd) external returns (uint256 cashbackAmountInToken, bool paid);

    /**
     * @notice Clear pending cashback for an account
     * @param account The address of the account
     * @param token The address of the cashback token
     * @param amountInUsd The amount of cashback in USD for the token
     * @return the amount of cashback in token
     * @return whether it was paid
     */
    function clearPendingCashback(address account, address token, uint256 amountInUsd) external returns (uint256, bool);

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
