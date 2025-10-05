// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICCTPTokenMessenger} from "../../interfaces/ICCTPTokenMessenger.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title CCTPAdapter
 * @notice Bridge adapter implementation for Circle CCTP (Cross-Chain Transfer Protocol)
 * @dev Extends BridgeAdapterBase to provide CCTP-specific bridging functionality
 * @author ether.fi
 */
contract CCTPAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when tokens are bridged through CCTP
     * @param token The address of the token being bridged
     * @param amount The amount of tokens being bridged
     * @param destinationDomain The destination domain ID
     * @param mintRecipient The recipient address on the destination domain
     */
    event BridgeViaCCTP(address token, uint256 amount, uint32 destinationDomain, bytes32 mintRecipient);

    /**
     * @notice Bridges tokens using the CCTP protocol
     * @dev Executes the bridge operation through CCTP's depositForBurn function
     * @param token The address of the token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param additionalData ABI-encoded data containing:
     *        - tokenMessenger: address of the CCTP TokenMessenger contract
     *        - destinationDomain: destination domain ID
     *        - maxFee: maximum fee to pay on destination domain (in burnToken units)
     *        - minFinalityThreshold: minimum finality threshold for message attestation
     */
    function bridge(
        address token,
        uint256 amount,
        address destRecipient,
        uint256 /*maxSlippage*/,
        bytes calldata additionalData
    ) external payable override {
        (address tokenMessenger, uint32 destinationDomain, uint256 maxFee, uint32 minFinalityThreshold) = 
            abi.decode(additionalData, (address, uint32, uint256, uint32));

        IERC20(token).forceApprove(tokenMessenger, amount);

        bytes32 mintRecipient = bytes32(uint256(uint160(destRecipient)));

        ICCTPTokenMessenger(tokenMessenger).depositForBurn(
            amount,
            destinationDomain,
            mintRecipient,
            token,
            bytes32(0),
            maxFee,
            minFinalityThreshold
        );

        emit BridgeViaCCTP(token, amount, destinationDomain, mintRecipient);
    }

    /**
     * @notice Calculates the fee required for bridging through CCTP
     * @dev CCTP doesn't require native ETH fees, returns 0
     * @return ETH address and 0 fee amount (CCTP doesn't charge native ETH fees)
     */
    function getBridgeFee(
        address /*token*/,
        uint256 /*amount*/,
        address /*destRecipient*/,
        uint256 /*maxSlippage*/,
        bytes calldata /*additionalData*/
    ) external pure override returns (address, uint256) {
        return (ETH, 0);
    }
}
