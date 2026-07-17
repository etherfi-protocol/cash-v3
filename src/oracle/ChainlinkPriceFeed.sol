// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { StablePriceLib } from "./StablePriceLib.sol";

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
contract ChainlinkPriceFeed is IAaveV4PriceFeed {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice The Chainlink feed: a USD price (no underlying) or a rate in the underlying asset
    IAggregatorV3 public immutable rateFeed;
    /// @notice The feed for the underlying asset's USD price; address(0) when the rate is USD-quoted
    IAaveV4PriceFeed public immutable underlyingUsdFeed;
    /// @notice The decimals of the rate feed
    uint8 public immutable rateDecimals;
    /// @notice The decimals of the underlying feed (0 when unset)
    uint8 public immutable underlyingDecimals;
    /// @notice The decimals of the price this feed reports
    uint8 public immutable feedDecimals;
    /// @notice The maximum age in seconds for the rate feed before it is rejected
    uint256 public immutable rateMaxStaleness;
    /// @notice Whether the price snaps to exactly 1 USD when within 1% of it (USD stables only)
    bool public immutable isStableToken;

    string private _description;

    /// @notice Thrown when the rate feed price is older than its staleness limit
    error StalePrice();
    /// @notice Thrown when either leg's price is zero or negative
    error InvalidPrice();
    /// @notice Thrown when the staleness bound is zero
    error InvalidMaxStaleness();

    constructor(IAggregatorV3 _rateFeed, IAaveV4PriceFeed _underlyingUsdFeed, uint8 _feedDecimals, uint256 _rateMaxStaleness, bool _isStableToken, string memory feedDescription) {
        require(_rateMaxStaleness > 0, InvalidMaxStaleness());
        rateFeed = _rateFeed;
        underlyingUsdFeed = _underlyingUsdFeed;
        rateDecimals = _rateFeed.decimals();
        if (address(_underlyingUsdFeed) != address(0)) {
            underlyingDecimals = _underlyingUsdFeed.decimals();
        }
        feedDecimals = _feedDecimals;
        rateMaxStaleness = _rateMaxStaleness;
        isStableToken = _isStableToken;
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
     * @notice The token's price: the Chainlink feed, times the underlying USD price when configured
     * @dev Reverts if the Chainlink feed is stale, or either leg is non-positive or reverts. The
     *      underlying leg enforces its own staleness.
     */
    function latestAnswer() external view returns (int256) {
        uint256 rate = _readFeed(rateFeed, rateMaxStaleness);

        // USD-quoted feed: scale straight to feed decimals.
        if (address(underlyingUsdFeed) == address(0)) {
            return StablePriceLib.snap(rate.mulDiv(10 ** feedDecimals, 10 ** rateDecimals), isStableToken, feedDecimals).toInt256();
        }

        int256 underlyingAnswer = underlyingUsdFeed.latestAnswer();
        if (underlyingAnswer <= 0) revert InvalidPrice();
        uint256 underlyingPrice = underlyingAnswer.toUint256();

        // price = rate * underlyingPrice, normalized from (rateDecimals + underlyingDecimals) to feedDecimals
        uint256 price = rate.mulDiv(underlyingPrice * 10 ** feedDecimals, 10 ** (rateDecimals + underlyingDecimals));

        return StablePriceLib.snap(price, isStableToken, feedDecimals).toInt256();
    }

    /// @dev Reads a Chainlink feed, reverting if the price is non-positive or older than maxStaleness
    function _readFeed(IAggregatorV3 feed, uint256 maxStaleness) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp > updatedAt + maxStaleness) revert StalePrice();
        return answer.toUint256();
    }
}
