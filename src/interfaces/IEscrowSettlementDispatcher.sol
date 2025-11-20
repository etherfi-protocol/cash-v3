// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IEscrowSettlementDispatcher
 * @notice Interface for EscrowSettlementDispatcher contract
 */
interface IEscrowSettlementDispatcher {
    /**
     * @notice Receives ERC20 tokens from CashModule spend function
     * @param safe Address of the safe sending the payment
     * @param token Address of the token being received
     * @param amount Amount of tokens being received
     */
    function receivePayment(address safe, address token, uint256 amount) external;

    /**
     * @notice Gets payment information for a safe
     * @param safe Address of the safe
     * @return state Payment state (0 = NoPayment, 1 = Payment, 2 = PaymentRefunded)
     * @return paymentToken Address of the payment token
     * @return amount Amount of the payment
     */
    function getPayment(address safe) external view returns (uint8 state, address paymentToken, uint256 amount);
    
    /**
     * @notice Gets total amount of a token held in escrow
     * @param token Address of the token
     * @return Total amount escrowed
     */
    function getEscrowedAmount(address token) external view returns (uint256);
}

