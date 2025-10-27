// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INttManager} from "../../interfaces/INTTManager.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title NTTAdapter
 * @notice Bridge adapter implementation for Native Token Transfer (NTT) Protocol
 * @dev Extends BridgeAdapterBase to provide NTT-specific bridging functionality
 * @author ether.fi
 */
contract NTTAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when tokens are bridged through NTT
     * @param token The address of the token being bridged
     * @param amount The amount of tokens being bridged
     * @param msgId The NTT message ID for tracking the transfer
     */
    event BridgeViaNTT(address token, uint256 amount, uint64 msgId);

    // https://wormhole.com/docs/build/reference/chain-ids/
    uint16 public constant DEST_EID_SCROLL = 34;

    /**
     * @notice Bridges tokens using the NTT protocol
     * @dev Executes the bridge operation through NTT's transfer function and removes dust from the amount
     * to avoid the transfer reverting due to the `TransferAmountHasDust` error
     * @param token The address of the token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param additionalData ABI-encoded NTT manager address and the amount of dust decimals to remove
     * @custom:throws InsufficientNativeFee if msg.value is less than required fee
     */
    function bridge(
        address token,
        uint256 amount,
        address destRecipient,
        uint256 /*maxSlippage*/,
        bytes calldata additionalData
    ) external payable override {
        (address nttManager, uint256 dustDecimals) = abi.decode(additionalData, (address, uint256));

        (,uint256 price) = INttManager(nttManager).quoteDeliveryPrice(DEST_EID_SCROLL, new bytes(1));
        if (address(this).balance < price) revert InsufficientNativeFee();

        IERC20(token).forceApprove(nttManager, amount);

        uint256 amountWithoutDust = (amount / 10 ** dustDecimals) * 10 ** dustDecimals;
        uint64 msgId = INttManager(nttManager).transfer{value: price}(amountWithoutDust, DEST_EID_SCROLL, bytes32(uint256(uint160(destRecipient))));
        emit BridgeViaNTT(token, amountWithoutDust, msgId);
    }

    /**
     * @notice Calculates the fee required for bridging through NTT
     * @dev Returns the native token fee required for the bridge operation
     * @param additionalData ABI-encoded NTT manager address
     * @return ETH address and the required native token fee amount
     */
    function getBridgeFee(
        address /*token*/,
        uint256 /*amount*/,
        address /*destRecipient*/,
        uint256 /*maxSlippage*/,
        bytes calldata additionalData
    ) external view override returns (address, uint256) {
        address nttManager = abi.decode(additionalData, (address));
        (,uint256 price) = INttManager(nttManager).quoteDeliveryPrice(DEST_EID_SCROLL, new bytes(1));
        return (ETH, price);
    }
}
