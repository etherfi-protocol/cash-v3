// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import { IL1ERC20Gateway, IL1MessageQueueV2, IL1ERC20Messenger, IL1GatewayRouter } from "../../interfaces/IScrollERC20Bridge.sol";

/**
 * @title ScrollERC20BridgeAdapter
 * @notice Adapter contract for bridging ERC20 tokens from Ethereum L1 to Scroll L2
 * @dev Implements BridgeAdapterBase interface to integrate with Scroll's bridge infrastructure
 *      This adapter is designed to be called via delegateCall from the TopUpFactory contract
 */
contract ScrollERC20BridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;   

    /**
     * @notice Emitted when ERC20 tokens are bridged
     * @param token The address of the token being bridged
     * @param amount The amount of tokens being bridged
     * @param destRecipient The recipient address on L2
     */
    event BridgeERC20(address indexed token, uint256 amount, address indexed destRecipient);

    /**
     * @notice Bridges ERC20 tokens from L1 to Scroll L2
     * @dev This function is called via delegateCall from TopUpFactory, so:
     *      - address(this) refers to the TopUpFactory contract
     *      - msg.sender is the original caller to TopUpFactory
     *      - msg.value is the ETH sent to TopUpFactory
     * @param token The address of the ERC20 token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on Scroll L2
     * @param maxSlippage Maximum allowed slippage in basis points (unused in Scroll bridge)
     * @param additionalData Encoded data containing gatewayRouter address and gasLimit
     * @custom:throws InsufficientNativeFee if contract has insufficient ETH balance for bridge fee
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external payable override {
        (address gatewayRouter, uint256 gasLimit) = abi.decode(additionalData, (address, uint256));
        (, uint256 fee) = getBridgeFee(token, amount, destRecipient, maxSlippage, additionalData);

        if (address(this).balance < fee) revert InsufficientNativeFee();
        IERC20(token).forceApprove(gatewayRouter, amount);
        IL1GatewayRouter(gatewayRouter).depositERC20{value: fee}(token, destRecipient, amount, gasLimit);

        emit BridgeERC20(token, amount, destRecipient);
    }

    /**
     * @notice Calculates the bridge fee required for transferring tokens to Scroll L2
     * @dev Queries the Scroll message queue to estimate the cross-domain message fee
     * @param token The address of the token to bridge
     * @param (unused) amount The amount of tokens to bridge 
     * @param (unused) destRecipient The recipient address on L2 
     * @param (unused) maxSlippage Maximum allowed slippage 
     * @param additionalData Encoded data containing gatewayRouter address and gasLimit
     * @return address The fee token address (always ETH for Scroll bridge)
     * @return uint256 The required fee amount in wei
     */
    function getBridgeFee(
        address token,
        uint256, // amount
        address, // destRecipient
        uint256, // maxSlippage
        bytes calldata additionalData
    ) public view override returns (address, uint256) {
        (address gatewayRouter, uint256 gasLimit) = abi.decode(additionalData, (address, uint256));
        IL1ERC20Gateway gateway = IL1ERC20Gateway(IL1GatewayRouter(gatewayRouter).getERC20Gateway(token));
        IL1ERC20Messenger messenger = IL1ERC20Messenger(gateway.messenger());
        IL1MessageQueueV2 messageQueue = IL1MessageQueueV2(messenger.messageQueueV2());

        return (ETH, messageQueue.estimateCrossDomainMessageFee(gasLimit));
    }
}
