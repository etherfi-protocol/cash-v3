// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";

/**
 * @title ChainlinkCompositePriceFeed
 * @notice Prices a token that has a Chainlink rate feed in an underlying asset rather than a direct USD
 *         feed, for example weETH priced as the weETH/ETH rate times ETH/USD. One instance per token.
 * @dev Implements the Aave v4 price-feed interface and fails closed: latestAnswer reverts when either
 *      Chainlink feed is stale or non-positive.
 * @author ether.fi
 */
contract ChainlinkCompositePriceFeed is IAaveV4PriceFeed {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice The Chainlink feed for the token's rate in the underlying asset, e.g. weETH/ETH
    IAggregatorV3 public immutable rateFeed;
    /// @notice The Chainlink feed for the underlying asset's USD price, e.g. ETH/USD
    IAggregatorV3 public immutable underlyingUsdFeed;
    /// @notice The decimals of the rate feed
    uint8 public immutable rateDecimals;
    /// @notice The decimals of the underlying Chainlink feed
    uint8 public immutable underlyingDecimals;
    /// @notice The decimals of the price this feed reports
    uint8 public immutable feedDecimals;
    /// @notice The maximum age in seconds for the rate feed before it is rejected
    uint256 public immutable rateMaxStaleness;
    /// @notice The maximum age in seconds for the underlying Chainlink price before it is rejected
    uint256 public immutable underlyingMaxStaleness;

    string private _description;

    /// @notice Thrown when either Chainlink price is older than its staleness limit
    error StalePrice();
    /// @notice Thrown when either Chainlink price is zero or negative
    error InvalidPrice();

    constructor(IAggregatorV3 _rateFeed, IAggregatorV3 _underlyingUsdFeed, uint8 _feedDecimals, uint256 _rateMaxStaleness, uint256 _underlyingMaxStaleness, string memory feedDescription) {
        rateFeed = _rateFeed;
        underlyingUsdFeed = _underlyingUsdFeed;
        rateDecimals = _rateFeed.decimals();
        underlyingDecimals = _underlyingUsdFeed.decimals();
        feedDecimals = _feedDecimals;
        rateMaxStaleness = _rateMaxStaleness;
        underlyingMaxStaleness = _underlyingMaxStaleness;
        _description = feedDescription;
    }

    /// @notice The number of decimals used to represent the price
    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    /// @notice A human-readable description of the feed
    function description() external view returns (string memory) {
        return _description;
    }

    /**
     * @notice The token's price, the rate feed times the underlying USD price
     * @dev Reverts if either Chainlink feed is stale or non-positive
     */
    function latestAnswer() external view returns (int256) {
        uint256 rate = _readFeed(rateFeed, rateMaxStaleness);
        uint256 underlyingPrice = _readFeed(underlyingUsdFeed, underlyingMaxStaleness);

        // price = rate * underlyingPrice, normalized from (rateDecimals + underlyingDecimals) to feedDecimals
        uint256 price = rate.mulDiv(underlyingPrice * 10 ** feedDecimals, 10 ** (rateDecimals + underlyingDecimals));

        return price.toInt256();
    }

    /// @dev Reads a Chainlink feed, reverting if the price is non-positive or older than maxStaleness
    function _readFeed(IAggregatorV3 feed, uint256 maxStaleness) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp > updatedAt + maxStaleness) revert StalePrice();
        return answer.toUint256();
    }
}
