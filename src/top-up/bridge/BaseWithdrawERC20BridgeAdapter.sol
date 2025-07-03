// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IL2StandardBridge } from "../../interfaces/IL2StandardBridge.sol";

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title BaseWithdrawERC20BridgeAdapter
 * @notice Adapter contract for withdrawing ERC20 tokens from Base to Ethereum
 * @dev Implements BridgeAdapterBase interface to integrate with Base's bridge infrastructure
 *      This adapter is designed to be called via delegateCall from the TopUpFactory contract
 */
contract BaseWithdrawERC20BridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    address public constant BRIDGE = 0x4200000000000000000000000000000000000010;

    /**
     * @notice Emitted when ERC20 tokens are bridge
     * @param token The address of the token being bridged
     * @param amount The amount of tokens being bridged
     * @param destRecipient The recipient address on 
     */
    event BridgeERC20(address indexed token, uint256 amount, address indexed destRecipient);

    /**
     * @notice Bridges ERC20 tokens from Base to Ethereum
     * @dev This function is called via delegateCall from TopUpFactory, so:
     *      - address(this) refers to the TopUpFactory contract
     *      - msg.sender is the original caller to TopUpFactory
     *      - msg.value is the ETH sent to TopUpFactory
     * @param token The address of the ERC20 token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on Ethereum
     * @param (unused) maxSlippage Maximum allowed slippage in basis points
     * @param additionalData Encoded data containing minGasLimit and extraData
     * @custom:throws InsufficientNativeFee if contract has insufficient ETH balance for bridge fee
     */
    function bridge(
        address token,
        uint256 amount,
        address destRecipient,
        uint256, // maxSlippage
        bytes calldata additionalData
    ) external payable override {
        (uint32 minGasLimit, bytes memory extraData) = abi.decode(additionalData, (uint32, bytes));
        IL2StandardBridge(BRIDGE).withdrawTo(token, destRecipient, amount, minGasLimit, extraData);

        emit BridgeERC20(token, amount, destRecipient);
    }

    /**
     * @notice Returns the bridge fee for Base to Ethereum
     * @dev There is no bridge fee for Base to Ethereum with native bridging
     */
    function getBridgeFee(
        address, // token
        uint256, // amount
        address, // destRecipient
        uint256, // maxSlippage
        bytes calldata // additionalData
    ) public view override returns (address, uint256) {
        return (ETH, 0);
    }
}
