// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IOFT, MessagingFee, MessagingReceipt, OFTFeeDetail, OFTLimit, OFTReceipt, SendParam, SendParam } from "../../interfaces/IOFT.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title EtherFiOFTBridgeAdapter
 * @notice Bridge adapter implementation for LayerZero's OFT (Omnichain Fungible Token) protocol
 * @dev Extends BridgeAdapterBase to provide OFT-specific bridging functionality
 * @author ether.fi
 */
contract EtherFiOFTBridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    // https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    uint32 public constant DEST_EID_SCROLL = 30_214;

    /**
     * @notice Emitted when tokens are bridged through OFT
     * @param token The address of the token being bridged
     * @param amount The amount of tokens being bridged
     * @param messageReceipt Receipt of the LayerZero message
     * @param oftReceipt Receipt of the OFT operation
     */
    event BridgeOFT(address indexed token, uint256 amount, MessagingReceipt messageReceipt, OFTReceipt oftReceipt);

    /**
     * @notice Bridges tokens using the OFT protocol
     * @dev Executes the bridge operation through LayerZero's OFT interface
     * @param token The address of the token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @param additionalData ABI-encoded OFT adapter address
     * @custom:throws InsufficientNativeFee if msg.value is less than required fee
     * @custom:throws InsufficientMinAmount if received amount is less than minimum
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external payable override {
        IOFT oftAdapter = IOFT(abi.decode(additionalData, (address)));
        uint256 minAmount = deductSlippage(amount, maxSlippage);

        SendParam memory sendParam = SendParam({ dstEid: DEST_EID_SCROLL, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: minAmount, extraOptions: hex"0003", composeMsg: new bytes(0), oftCmd: new bytes(0) });

        MessagingFee memory messagingFee = oftAdapter.quoteSend(sendParam, false);
        if (address(this).balance < messagingFee.nativeFee) revert InsufficientNativeFee();

        if (oftAdapter.approvalRequired()) IERC20(token).forceApprove(address(oftAdapter), amount);

        (MessagingReceipt memory messageReceipt, OFTReceipt memory oftReceipt) = oftAdapter.send{ value: messagingFee.nativeFee }(sendParam, messagingFee, payable(address(this)));
        if (oftReceipt.amountReceivedLD < minAmount) revert InsufficientMinAmount();

        emit BridgeOFT(token, amount, messageReceipt, oftReceipt);
    }

    /**
     * @notice Calculates the native token fee required for bridging
     * @dev Queries the OFT adapter for the messaging fee
     * @param token Unused in this implementation
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @param additionalData ABI-encoded OFT adapter address
     * @return ETH address and the required native token fee amount
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external view override returns (address, uint256) {
        // Silence compiler warning on unused variables.
        token = token;

        IOFT oftAdapter = IOFT(abi.decode(additionalData, (address)));
        uint256 minAmount = deductSlippage(amount, maxSlippage);

        SendParam memory sendParam = SendParam({ dstEid: DEST_EID_SCROLL, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: minAmount, extraOptions: hex"0003", composeMsg: new bytes(0), oftCmd: new bytes(0) });

        MessagingFee memory messagingFee = oftAdapter.quoteSend(sendParam, false);

        return (ETH, messagingFee.nativeFee);
    }
}
