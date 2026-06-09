// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPriceRelay
 * @author ether.fi
 * @notice Mainnet-side LayerZero sender that pushes normalised USD prices to a
 *         destination-chain {IOracleSink}.
 * @dev Reads from the existing mainnet {PriceProvider} (already 6-decimal USD),
 *      then `_lzSend`s a packed update for one or more subscribed tokens.
 *
 *      The LayerZero native fee is paid from the relay contract's own balance
 *      (see {fund}/{withdraw}), so `poke` is permissionless and non-payable:
 *      anyone can trigger a relay, but a send only actually happens when a
 *      per-token heartbeat or deviation threshold is crossed. This prevents a
 *      spammer from draining the contract's balance with redundant pokes.
 */
interface IPriceRelay {
    /**
     * @notice Per-token relay configuration
     * @param heartbeat Force a relay if the last send for this token is older than
     *                  this many seconds (the "max staleness" floor on the source side)
     * @param deviationBps Relay early if the source price moved at least this many
     *                     basis points since the last send (1 = 0.01%)
     * @param maxStaleness Recorded for the destination/off-chain consumers so a single
     *                     source of truth exists; not enforced on this contract
     */
    struct TokenSubscription {
        uint32 heartbeat;
        uint32 deviationBps;
        uint32 maxStaleness;
    }

    /// @notice Emitted when a token is subscribed for relay
    event TokenSubscribed(address indexed token, TokenSubscription config);
    /// @notice Emitted when a token is unsubscribed from relay
    event TokenUnsubscribed(address indexed token);
    /// @notice Emitted when the destination EID (OracleSink chain) is updated
    event DestinationEidSet(uint32 indexed dstEid);
    /// @notice Emitted on a successful poke that pushed `n` token prices
    event PricesRelayed(uint32 indexed dstEid, address[] tokens, uint256[] prices);
    /// @notice Emitted when the LayerZero execution options are updated
    event LzOptionsSet(bytes options);
    /// @notice Emitted when the contract is funded with native currency for fees
    event Funded(address indexed from, uint256 amount);
    /// @notice Emitted when native currency is withdrawn from the contract
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice Thrown when an array argument is empty or two arrays have mismatched lengths
    error InvalidInput();
    /// @notice Thrown when a token is not subscribed for relay
    error TokenNotSubscribed();
    /// @notice Thrown when the source PriceProvider returns a stale price
    error StaleSourcePrice();
    /// @notice Thrown when the destination EID has not been configured
    error DestinationNotSet();
    /// @notice Thrown when no subscribed token in the poke crossed its heartbeat/deviation gate
    error NothingToRelay();
    /// @notice Thrown when the contract's balance cannot cover the LayerZero native fee
    error InsufficientBalance();
    /// @notice Thrown when a native withdrawal transfer fails
    error WithdrawFailed();

    /**
     * @notice Subscribe `token` for cross-chain price relay
     * @dev Admin-only. Token must already be configured on the mainnet {PriceProvider}.
     * @param token ERC-20 to relay
     * @param config Subscription parameters (heartbeat, deviation trigger, staleness)
     */
    function subscribe(address token, TokenSubscription calldata config) external;

    /**
     * @notice Remove `token` from the relay set
     * @param token ERC-20 to drop
     */
    function unsubscribe(address token) external;

    /**
     * @notice Permissionless price push for one or more subscribed tokens
     * @dev The LayerZero fee is paid from this contract's balance. Only tokens whose
     *      heartbeat elapsed or whose price deviated past the configured threshold are
     *      actually relayed; if none qualify the call reverts with {NothingToRelay}.
     * @param tokens Subscribed tokens to consider for relay
     */
    function poke(address[] calldata tokens) external;

    /**
     * @notice Quote the LayerZero native fee for relaying `tokens`
     * @dev Upper bound: quotes as if all provided tokens were relayed.
     * @param tokens Subscribed tokens that would be relayed
     * @return nativeFee Native fee that would be drawn from the contract balance
     * @return lzTokenFee Fee in LZ token (if paying in ZRO; 0 otherwise)
     */
    function quote(address[] calldata tokens) external view returns (uint256 nativeFee, uint256 lzTokenFee);

    /**
     * @notice Sets the LayerZero execution options used for every relay send
     * @dev Admin-only. Options fix the gas/value delivered to {IOracleSink} on the
     *      destination chain; stored on-chain so permissionless callers cannot grief.
     * @param options Encoded LayerZero execution options
     */
    function setLzOptions(bytes calldata options) external;

    /**
     * @notice Withdraw native currency used to fund relay fees
     * @dev Admin-only.
     * @param to Recipient
     * @param amount Amount of native currency to withdraw
     */
    function withdraw(address to, uint256 amount) external;

    /**
     * @notice Returns the subscription config for `token`
     * @param token Token to query
     * @return config Subscription parameters; default-zero struct if unsubscribed
     */
    function subscriptionOf(address token) external view returns (TokenSubscription memory config);

    /**
     * @notice Returns the last relayed price and timestamp for `token`
     * @param token Token to query
     * @return price Last relayed price (6-decimal USD); 0 if never relayed
     * @return timestamp Block timestamp of the last relay; 0 if never relayed
     */
    function lastRelayed(address token) external view returns (uint256 price, uint64 timestamp);

    /**
     * @notice Returns the LayerZero execution options used for relay sends
     * @return options The encoded options
     */
    function lzOptions() external view returns (bytes memory options);

    /**
     * @notice Returns the destination LayerZero endpoint ID (OracleSink chain)
     * @return dstEid The destination EID
     */
    function destinationEid() external view returns (uint32 dstEid);
}
