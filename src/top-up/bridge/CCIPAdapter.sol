// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// solhint-disable-next-line max-line-length
import { EVM2AnyMessage, EVMTokenAmount, GENERIC_EXTRA_ARGS_V2_TAG, GenericExtraArgsV2, ICCIPRouter } from "../../interfaces/ICCIPRouter.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title CCIPAdapter
 * @notice Bridge adapter implementation for Chainlink CCIP (Cross-Chain Interoperability
 *         Protocol). Sends a token-only CCIP message to the recipient on the destination
 *         chain, paying the CCIP fee in native.
 * @dev Delegatecalled by `TopUpFactory.bridge()`, so the tokens and the approval belong to
 *      the factory. `additionalData` is `abi.encode(address router, uint64 destChainSelector)`.
 *      Note that a CCIP chain selector is neither a chain id nor a LayerZero EID — it is
 *      CCIP's own destination identifier and must be read off Chainlink's CCIP directory.
 *
 *      Three properties of CCIP drive the shape of this adapter:
 *
 *      1. The message is token-only: `data` is empty and `extraArgs` sets `gasLimit: 0`.
 *         That combination makes the destination OffRamp treat the message as a pure
 *         transfer and release the tokens straight to `destRecipient` without ever calling
 *         `ccipReceive`, so the recipient does not need to be an `IAny2EVMMessageReceiver`.
 *         Leaving `extraArgs` empty instead would make CCIP bill a default 200,000 gas
 *         limit for a call that never happens. `allowOutOfOrderExecution` is set because
 *         lanes that enforce out-of-order execution reject messages that disallow it.
 *
 *      2. The fee is paid in native (`feeToken == address(0)`) because that is the only
 *         thing `TopUpFactory.bridge()` can fund — it checks the quote against `msg.value`.
 *         The send passes exactly the quoted fee: the Router wraps the whole `msg.value`
 *         and refunds nothing above the quote, so forwarding the factory's balance would
 *         hand over every spare wei it holds.
 *
 *      3. `maxSlippage` is unused. CCIP token pools move the amount 1:1 (ZCHF, for
 *         instance, is burn/mint on both ends of the lane) and `ccipSend` returns only a
 *         message id, never a received amount — there is nothing to floor. Token configs
 *         for this adapter should therefore use `maxSlippageInBps: 0`.
 * @author ether.fi
 */
contract CCIPAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when tokens are bridged through CCIP.
     * @param token The address of the token being bridged.
     * @param amount The amount of tokens being bridged.
     * @param destChainSelector CCIP chain selector of the destination chain.
     * @param destRecipient The recipient address on the destination chain.
     * @param messageId CCIP message id, for tracking the transfer across chains.
     */
    event BridgeViaCCIP(address indexed token, uint256 amount, uint64 destChainSelector, address destRecipient, bytes32 messageId);

    /**
     * @notice Bridges tokens using CCIP.
     * @dev Approves the Router, which is what pulls the tokens, then sends the token-only
     *      message with exactly the quoted native fee attached.
     * @param token The address of the token to bridge. Must have a CCIP token pool
     *        registered for this lane, or the send reverts.
     * @param amount The amount of tokens to bridge.
     * @param destRecipient The recipient address on the destination chain.
     * @param additionalData ABI-encoded (address router, uint64 destChainSelector).
     * @custom:throws InsufficientNativeFee if the balance can't cover the CCIP fee.
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256 /*maxSlippage*/, bytes calldata additionalData) external payable override {
        (address router, uint64 destChainSelector) = abi.decode(additionalData, (address, uint64));
        EVM2AnyMessage memory message = _buildMessage(token, amount, destRecipient);

        uint256 fee = ICCIPRouter(router).getFee(destChainSelector, message);
        if (address(this).balance < fee) revert InsufficientNativeFee();

        // The Router transfers `amount` out of this contract, so it is the approval target.
        // It takes exactly `amount`, leaving no residual allowance behind.
        IERC20(token).forceApprove(router, amount);

        bytes32 messageId = ICCIPRouter(router).ccipSend{ value: fee }(destChainSelector, message);

        emit BridgeViaCCIP(token, amount, destChainSelector, destRecipient, messageId);
    }

    /**
     * @notice Calculates the native fee required for bridging through CCIP.
     * @dev Quotes the exact message `bridge` would send, so the factory's `msg.value`
     *      check and the send itself agree within a block.
     * @param token The address of the token to bridge.
     * @param amount The amount of tokens to bridge.
     * @param destRecipient The recipient address on the destination chain.
     * @param additionalData ABI-encoded (address router, uint64 destChainSelector).
     * @return ETH address and the required native fee amount.
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256 /*maxSlippage*/, bytes calldata additionalData) external view override returns (address, uint256) {
        (address router, uint64 destChainSelector) = abi.decode(additionalData, (address, uint64));
        return (ETH, ICCIPRouter(router).getFee(destChainSelector, _buildMessage(token, amount, destRecipient)));
    }

    /**
     * @dev Builds the token-only CCIP message: no payload, one token, native fee, and
     *      `gasLimit: 0` execution options so the destination is never called. See the
     *      contract-level notes for why each field is what it is.
     */
    function _buildMessage(address token, uint256 amount, address destRecipient) internal pure returns (EVM2AnyMessage memory) {
        EVMTokenAmount[] memory tokenAmounts = new EVMTokenAmount[](1);
        tokenAmounts[0] = EVMTokenAmount({ token: token, amount: amount });

        return EVM2AnyMessage({ receiver: abi.encode(destRecipient), data: new bytes(0), tokenAmounts: tokenAmounts, feeToken: address(0), extraArgs: abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, GenericExtraArgsV2({ gasLimit: 0, allowOutOfOrderExecution: true })) });
    }
}
