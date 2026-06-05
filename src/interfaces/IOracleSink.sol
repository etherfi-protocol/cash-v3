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

    /// @notice Thrown when a token has never received a relayed price
    error PriceNotSet();

    /**
     * @notice Returns the latest relayed price for `token` in {DECIMALS} precision
     * @param token Token to query
     * @return price Normalised USD price (6 decimals)
     * @return updatedAt Timestamp at which the price was received on this chain
     */
    function getPrice(address token) external view returns (uint256 price, uint64 updatedAt);

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
