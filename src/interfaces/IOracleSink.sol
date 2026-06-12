// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOracleSink
 * @author ether.fi
 * @notice Destination-chain LayerZero receiver that exposes relayed prices in a
 *         Chainlink-compatible shape so the existing {PriceProvider} can read them
 *         via its standard `isChainlinkType` config branch.
 */
interface IOracleSink {
    /**
     * @notice Per-token latest relayed price
     * @param price Normalised USD price with {DECIMALS} precision (6)
     * @param updatedAt Block timestamp (on this chain) when the update was received
     */
    struct PricePoint {
        uint256 price;
        uint64 updatedAt;
    }

    /// @notice Emitted when a relayed price update is stored
    event PriceUpdated(address indexed token, uint256 price, uint64 updatedAt);
    /// @notice Emitted when the per-token max staleness window is configured
    event MaxStalenessSet(address indexed token, uint64 maxStaleness);

    /// @notice Thrown when a token has never received a relayed price
    error PriceNotSet();
    /// @notice Thrown when the last relayed price for a token is older than its max staleness window
    error PriceStale();
    /// @notice Thrown when a zero address is supplied where it is not allowed
    error InvalidToken();

    /**
     * @notice Returns the latest relayed price for `token` in {DECIMALS} precision
     * @param token Token to query
     * @return price Normalised USD price (6 decimals)
     * @return updatedAt Timestamp at which the price was received on this chain
     */
    function getPrice(address token) external view returns (uint256 price, uint64 updatedAt);

    /**
     * @notice Returns the latest relayed price for `token` as a single value, reverting if stale.
     * @dev Designed for direct consumption by {PriceProvider} via its calldata branch:
     *      configure `isChainlinkType = false`, `dataType = Uint256`, `oraclePriceDecimals = 6`,
     *      `oracle = address(thisSink)` and
     *      `priceFunctionCalldata = abi.encodeWithSelector(IOracleSink.price.selector, token)`.
     *      Freshness is enforced here against the relay-delivery timestamp, so no per-token
     *      Chainlink adapter is required. A non-zero {maxStaleness} for the token must be set,
     *      otherwise no staleness check is applied.
     * @param token Token to query
     * @return Normalised USD price (6 decimals)
     */
    function price(address token) external view returns (uint256);

    /**
     * @notice Sets the maximum age (in seconds) of a relayed price before {price} reverts.
     * @dev Admin-gated. A value of 0 disables the staleness check for the token.
     * @param token Token to configure
     * @param maxStaleness Max age in seconds; 0 disables the check
     */
    function setMaxStaleness(address token, uint64 maxStaleness) external;

    /**
     * @notice Returns the configured max staleness window (seconds) for `token` (0 = disabled)
     * @param token Token to query
     */
    function maxStaleness(address token) external view returns (uint64);

    /**
     * @notice Chainlink AggregatorV3-style accessor consumed by {PriceProvider}
     * @dev `token` is supplied by the caller because a single sink serves many tokens.
     *      `roundId` and `answeredInRound` are always 0 (single-feed semantics).
     * @param token Token to query
     * @return roundId Always 0
     * @return answer USD price (6 decimals) as int256
     * @return startedAt Same as `updatedAt`
     * @return updatedAt Timestamp at which the price was received on this chain
     * @return answeredInRound Always 0
     */
    function latestRoundData(address token) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @notice Decimal precision of all prices exposed by this sink
     * @return Always 6 (matches {PriceProvider}.DECIMALS)
     */
    function decimals() external pure returns (uint8);
}
