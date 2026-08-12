// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The slice of the cash-mainnet-asset-listing OracleSink the OracleSinkPriceFeed reads: the
///         token-keyed Chainlink-shaped accessor, whose `updatedAt` is the source-chain time the relay
///         read the price (not the LayerZero delivery time), and the sink's fixed price decimals.
interface IOracleSink {
    function latestRoundData(address token) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}
