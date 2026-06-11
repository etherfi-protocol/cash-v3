// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPriceRelay
 * @author ether.fi
 * @notice Mainnet-side LayerZero sender that pushes normalised USD prices to a
 *         destination-chain {IOracleSink}.
 * @dev Reads from the existing mainnet {PriceProvider} (already 6-decimal USD)
 *      and `_lzSend`s the price of every subscribed token in one message.
 *
 *      Caller-pays: {poke} is payable and the LayerZero fee is taken from
 *      `msg.value` (excess refunded), so there is no protocol balance to drain
 *      and no on-chain gating. The off-chain keeper decides when to relay.
 */
interface IPriceRelay {
    /// @notice Emitted when a token is added to the relay allowlist
    event TokenSubscribed(address indexed token);
    /// @notice Emitted when a token is removed from the relay allowlist
    event TokenUnsubscribed(address indexed token);
    /// @notice Emitted when the destination EID (OracleSink chain) is updated
    event DestinationEidSet(uint32 indexed dstEid);
    /// @notice Emitted on a successful poke that pushed the subscribed token prices
    event PricesRelayed(uint32 indexed dstEid, address[] tokens, uint256[] prices);
    /// @notice Emitted when the destination lzReceive executor gas limit is updated
    event LzReceiveGasLimitSet(uint128 gasLimit);

    /// @notice Thrown when an input is invalid (zero address, or no tokens subscribed)
    error InvalidInput();
    /// @notice Thrown when unsubscribing a token that is not subscribed
    error TokenNotSubscribed();
    /// @notice Thrown when the destination EID has not been configured
    error DestinationNotSet();
    /// @notice Thrown when `msg.value` is below the quoted LayerZero fee
    error InsufficientFee();

    /**
     * @notice Add `token` to the relay allowlist
     * @dev Admin-only. Token must be configured on the mainnet {PriceProvider}.
     * @param token ERC-20 to relay
     */
    function subscribe(address token) external;

    /**
     * @notice Remove `token` from the relay allowlist
     * @param token ERC-20 to drop
     */
    function unsubscribe(address token) external;

    /**
     * @notice Relay the current price of every subscribed token to the destination chain
     * @dev Payable: the caller must supply at least the {quote}d LayerZero native fee in `msg.value`;
     *      the endpoint refunds any surplus to the caller. Reverts if no token is subscribed.
     */
    function poke() external payable;

    /**
     * @notice Quote the LayerZero native fee for relaying all subscribed tokens
     * @return nativeFee Native fee the caller must supply to {poke}
     */
    function quote() external view returns (uint256 nativeFee);

    /**
     * @notice Sets the executor gas limit delivered to {IOracleSink}.lzReceive on the destination chain
     * @dev Admin-only. Size it for the largest subscribed-token batch (the relay sends all tokens in one message).
     * @param gasLimit Destination lzReceive gas limit
     */
    function setLzReceiveGasLimit(uint128 gasLimit) external;

    /**
     * @notice Returns the list of subscribed tokens
     * @return tokens The allow-listed tokens relayed on each {poke}
     */
    function subscribedTokens() external view returns (address[] memory tokens);

    /**
     * @notice Returns whether `token` is on the relay allowlist
     * @param token Token to query
     * @return subscribed True if the token is relayed
     */
    function isSubscribed(address token) external view returns (bool subscribed);

    /**
     * @notice Returns the destination lzReceive executor gas limit
     * @return gasLimit The configured gas limit
     */
    function lzReceiveGasLimit() external view returns (uint128 gasLimit);

    /**
     * @notice Returns the destination LayerZero endpoint ID (OracleSink chain)
     * @return dstEid The destination EID
     */
    function destinationEid() external view returns (uint32 dstEid);
}
