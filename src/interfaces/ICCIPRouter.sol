// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice One token and amount inside a CCIP message. Mirrors `Client.EVMTokenAmount`.
 * @param token Address of the token on the source chain.
 * @param amount Amount in the token's own decimals.
 */
struct EVMTokenAmount {
    address token;
    uint256 amount;
}

/**
 * @notice An outbound CCIP message. Mirrors `Client.EVM2AnyMessage`.
 * @param receiver `abi.encode(recipient)` for EVM destinations.
 * @param data Arbitrary payload delivered to the receiver's `ccipReceive`. Empty for a
 *        token-only transfer, which is what makes the destination OffRamp skip the
 *        receiver call entirely.
 * @param tokenAmounts Tokens to move. Each needs a pool registered for the lane.
 * @param feeToken Token the CCIP fee is paid in; `address(0)` means pay in native, which
 *        the Router wraps on the caller's behalf.
 * @param extraArgs Tagged, versioned execution options — see `GenericExtraArgsV2`. Leaving
 *        this empty makes CCIP fall back to a 200,000 gas limit and bill for it.
 */
struct EVM2AnyMessage {
    bytes receiver;
    bytes data;
    EVMTokenAmount[] tokenAmounts;
    address feeToken;
    bytes extraArgs;
}

/**
 * @notice V2 execution options, ABI-encoded behind `GENERIC_EXTRA_ARGS_V2_TAG`.
 * @param gasLimit Maximum gas CCIP may spend calling `ccipReceive` on the destination.
 *        Zero for a token-only transfer: there is no call to pay for.
 * @param allowOutOfOrderExecution Whether the message may execute before earlier messages
 *        from the same sender. Lanes that set `enforceOutOfOrder` reject `false`.
 */
struct GenericExtraArgsV2 {
    uint256 gasLimit;
    bool allowOutOfOrderExecution;
}

/// @dev `bytes4(keccak256("CCIP EVMExtraArgsV2"))`, the tag CCIP's FeeQuoter uses to
///      recognise a `GenericExtraArgsV2` payload.
bytes4 constant GENERIC_EXTRA_ARGS_V2_TAG = 0x181dcf10;

/**
 * @title ICCIPRouter
 * @notice Minimal interface for the Chainlink CCIP Router — the send-side entry point of
 *         Chainlink's Cross-Chain Interoperability Protocol.
 * @dev Hand-written against Chainlink's `IRouterClient` and `Client` library rather than
 *      vendoring `chainlink-ccip`, matching how the other third-party bridges are wired
 *      up here (`ICCTPTokenMessenger`, `INttManager`, `IStargate`).
 *
 *      Two behaviours of the deployed Router that callers must respect:
 *      - Tokens are pulled from `msg.sender`, so the **Router** is the address to approve.
 *      - When paying in native, the Router wraps the whole `msg.value` and refunds nothing
 *        above the quoted fee. Send exactly `getFee`, never a whole balance.
 * @author ether.fi
 */
interface ICCIPRouter {
    /// @notice Thrown by `ccipSend` when no onRamp is configured for `destChainSelector`.
    error UnsupportedDestinationChain(uint64 destChainSelector);

    /// @notice Thrown by `ccipSend` when the supplied fee payment is below the quote.
    error InsufficientFeeTokenAmount();

    /// @notice Thrown when `token` has no CCIP token pool registered for the lane. Raised
    ///         from `getFee` as well as `ccipSend`, so an unusable config cannot even quote.
    error UnsupportedToken(address token);

    /**
     * @notice Whether a destination chain is currently reachable from this Router.
     * @param destChainSelector CCIP chain selector of the destination.
     * @return supported True if a lane to that chain is configured.
     */
    function isChainSupported(uint64 destChainSelector) external view returns (bool supported);

    /**
     * @notice Quotes the fee for delivering `message`.
     * @dev With `message.feeToken == address(0)` the quote is denominated in native.
     * @param destinationChainSelector CCIP chain selector of the destination.
     * @param message The message that would be sent.
     * @return fee Fee in `message.feeToken`.
     */
    function getFee(uint64 destinationChainSelector, EVM2AnyMessage memory message) external view returns (uint256 fee);

    /**
     * @notice Sends `message` to the destination chain.
     * @dev Pulls `message.tokenAmounts` from `msg.sender`, so approve this Router first.
     * @param destinationChainSelector CCIP chain selector of the destination.
     * @param message The message to send.
     * @return messageId Identifier for tracking the message across chains.
     */
    function ccipSend(uint64 destinationChainSelector, EVM2AnyMessage calldata message) external payable returns (bytes32 messageId);
}
