// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ISpokePool
 * @author ether.fi
 * @notice Minimal Across V3 SpokePool interface limited to the surface we call
 *         (`depositV3`). Across-side selector + arg order is canonical.
 */
interface ISpokePool {
    /**
     * @notice Deposits source-chain funds for a V3 cross-chain relay. The relayer fills on
     *         the destination chain; if no fill by `fillDeadline`, source funds auto-refund
     *         to `depositor`.
     * @param depositor Source-chain refund recipient.
     * @param recipient Destination-chain recipient (set to MulticallHandler for the
     *        sandwich-composed-swap flow).
     * @param inputToken Source-chain ERC20.
     * @param outputToken Destination-chain ERC20 the relayer is committing to deliver.
     * @param inputAmount Amount of `inputToken` deposited.
     * @param outputAmount Minimum amount of `outputToken` the relayer must deliver.
     * @param destinationChainId Destination chain ID.
     * @param exclusiveRelayer Optional exclusive relayer (0 = open).
     * @param quoteTimestamp Across quote timestamp; SpokePool enforces freshness.
     * @param fillDeadline Unix timestamp after which the deposit can be refunded source-side.
     * @param exclusivityDeadline Unix timestamp until which only `exclusiveRelayer` may fill.
     * @param message Destination-side payload; for MulticallHandler, an
     *        `Instructions(Call[] calls, address fallbackRecipient)` abi.encoded blob.
     */
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;
}
