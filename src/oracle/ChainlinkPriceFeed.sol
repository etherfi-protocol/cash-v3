// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { BaseAaveV4PriceFeed } from "./BaseAaveV4PriceFeed.sol";

/**
 * @title ChainlinkPriceFeed
 * @notice Prices a token for the Aave v4 oracle from a staleness-checked Chainlink feed.
 *         One instance per token, two modes like PythPriceFeed / VedaAccountantPriceFeed:
 *         - No underlying feed (address(0)): the Chainlink feed is already USD-quoted (e.g.
 *           ETH/USD) and is only scaled to feed decimals.
 *         - With an underlying feed: the Chainlink feed is a rate in an underlying asset (e.g.
 *           weETH/ETH, weEUR/EUR) and the price is rate x underlying USD, where the underlying is
 *           any IAaveV4PriceFeed — another ChainlinkPriceFeed, a PythPriceFeed, a
 *           VedaAccountantPriceFeed — which enforces its own staleness.
 * @dev Implements the Aave v4 price-feed interface and fails closed: latestAnswer reverts when the
 *      Chainlink feed is stale, or either leg is non-positive or reverts.
 * @author ether.fi
 */
contract ChainlinkPriceFeed is BaseAaveV4PriceFeed {
    using SafeCast for int256;

    /// @notice The Chainlink feed: a USD price (no underlying) or a rate in the underlying asset
    IAggregatorV3 public immutable rateFeed;
    /// @notice The maximum age in seconds for the rate feed before it is rejected
    uint256 public immutable rateMaxStaleness;

    constructor(IAggregatorV3 _rateFeed, IAaveV4PriceFeed _underlyingUsdFeed, uint8 _feedDecimals, uint256 _rateMaxStaleness, bool _isStableToken, string memory feedDescription) BaseAaveV4PriceFeed(_underlyingUsdFeed, _feedDecimals, _rateFeed.decimals(), _isStableToken, feedDescription) {
        require(_rateMaxStaleness > 0, InvalidMaxStaleness());
        rateFeed = _rateFeed;
        rateMaxStaleness = _rateMaxStaleness;
    }

    /**
     * @notice The token's price: the Chainlink feed, times the underlying USD price when configured
     * @dev Reverts if the Chainlink feed is stale, or either leg is non-positive or reverts. The
     *      underlying leg enforces its own staleness.
     */
    function latestAnswer() external view returns (int256) {
        return _composeUsd(_readFeed(rateFeed, rateMaxStaleness));
    }

    /// @dev Reads a Chainlink feed, reverting if the price is non-positive or older than maxStaleness
    function _readFeed(IAggregatorV3 feed, uint256 maxStaleness) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp > updatedAt + maxStaleness) revert StalePrice();
        return answer.toUint256();
    }
}
