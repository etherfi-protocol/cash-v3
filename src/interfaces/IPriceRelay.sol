// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPriceRelay
 * @author ether.fi
 * @notice Mainnet-side LayerZero sender that pushes normalised USD prices to a
 *         destination-chain {IOracleSink}.
 * @dev Reads from the existing mainnet {PriceProvider} (already 6-decimal USD),
 *      then `_lzSend`s a packed update for one or more subscribed tokens.
 */
interface IPriceRelay {
    /**
     * @notice Per-token relay configuration
     * @param maxStaleness Reject pokes whose source price is older than this (seconds)
     * @param deviationBps Reserved for off-chain keepers; recorded so a single source
     *                    of truth exists for the deviation trigger (basis points, 1 = 0.01%)
     */
    struct TokenSubscription {
        uint32 maxStaleness;
        uint32 deviationBps;
    }

    /// @notice Emitted when a token is subscribed for relay
    event TokenSubscribed(address indexed token, TokenSubscription config);
    /// @notice Emitted when a token is unsubscribed from relay
    event TokenUnsubscribed(address indexed token);
    /// @notice Emitted when the destination EID (OracleSink chain) is updated
    event DestinationEidSet(uint32 indexed dstEid);
    /// @notice Emitted on a successful poke that pushed `n` token prices
    event PricesRelayed(uint32 indexed dstEid, address[] tokens, uint256[] prices);

    /// @notice Thrown when an array argument is empty or two arrays have mismatched lengths
    error InvalidInput();
    /// @notice Thrown when a token is not subscribed for relay
    error TokenNotSubscribed();
    /// @notice Thrown when the source PriceProvider returns a stale price
    error StaleSourcePrice();
    /// @notice Thrown when the destination EID has not been configured
    error DestinationNotSet();

    /**
     * @notice Subscribe `token` for cross-chain price relay
     * @dev Admin-only. Token must already be configured on the mainnet {PriceProvider}.
     * @param token ERC-20 to relay
     * @param config Subscription parameters (staleness, deviation trigger)
     */
    function subscribe(address token, TokenSubscription calldata config) external;

    /**
     * @notice Remove `token` from the relay set
     * @param token ERC-20 to drop
     */
    function unsubscribe(address token) external;

    /**
     * @notice Permissionless price push for one or more subscribed tokens
     * @dev Caller funds the LayerZero native fee via `msg.value`. Excess is refunded.
     * @param tokens Subscribed tokens to relay
     * @param options Encoded LayerZero execution options (gas/value on the OP side)
     */
    function poke(address[] calldata tokens, bytes calldata options) external payable;

    /**
     * @notice Quote the LayerZero native fee for a poke of `tokens`
     * @param tokens Subscribed tokens that would be relayed
     * @param options Encoded LayerZero execution options
     * @return nativeFee Native fee that must be supplied as `msg.value`
     * @return lzTokenFee Fee in LZ token (if paying in ZRO; 0 otherwise)
     */
    function quote(address[] calldata tokens, bytes calldata options) external view returns (uint256 nativeFee, uint256 lzTokenFee);

    /**
     * @notice Returns the subscription config for `token`
     * @param token Token to query
     * @return config Subscription parameters; default-zero struct if unsubscribed
     */
    function subscriptionOf(address token) external view returns (TokenSubscription memory config);

    /**
     * @notice Returns the destination LayerZero endpoint ID (OracleSink chain)
     * @return dstEid The destination EID
     */
    function destinationEid() external view returns (uint32 dstEid);
}
