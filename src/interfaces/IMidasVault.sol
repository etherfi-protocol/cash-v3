// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMidasVault {
    /**
     * @notice depositing proccess with auto mint if
     * account fit daily limit and token allowance.
     * Transfers token from the user.
     * Transfers fee in tokenIn to feeReceiver.
     * Mints mToken to user.
     * @param tokenIn address of tokenIn
     * @param amountToken amount of `tokenIn` that will be taken from user (decimals 18)
     * @param minReceiveAmount minimum expected amount of mToken to receive (decimals 18)
     * @param referrerId referrer id
     */
    function depositInstant(address tokenIn, uint256 amountToken, uint256 minReceiveAmount, bytes32 referrerId) external;

    /**
     * @notice redeem mToken to tokenOut if daily limit and allowance not exceeded
     * Burns mToken from the user.
     * Transfers fee in mToken to feeReceiver
     * Transfers tokenOut to user.
     * @param tokenOut stable coin token address to redeem to
     * @param amountMTokenIn amount of mToken to redeem (decimals 18)
     * @param minReceiveAmount minimum expected amount of tokenOut to receive (decimals 18)
     */
    function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external;

    /**
     * @notice creating redeem request if tokenOut not fiat
     * Transfers amount in mToken to contract
     * Transfers fee in mToken to feeReceiver
     * @param tokenOut stable coin token address to redeem to
     * @param amountMTokenIn amount of mToken to redeem (decimals 18)
     * @return request id
     */
    function redeemRequest(address tokenOut, uint256 amountMTokenIn) external returns (uint256);
}
