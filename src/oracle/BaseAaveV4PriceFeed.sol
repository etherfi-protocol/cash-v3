// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { StablePriceLib } from "./StablePriceLib.sol";

/**
 * @title BaseAaveV4PriceFeed
 * @notice Shared state and math for the Aave v4 receipt-token price feeds. Every feed reports a
 *         feedDecimals-scaled USD price in one of two modes: a USD-quoted source scaled straight to feed
 *         decimals, or a rate in an underlying asset multiplied by that underlying's USD price (any
 *         IAaveV4PriceFeed, which enforces its own staleness). A derived feed supplies only the raw rate
 *         and its decimals from its own source; this base owns the two-mode compose, the stable snap,
 *         decimals(), description(), and the shared errors.
 * @author ether.fi
 */
abstract contract BaseAaveV4PriceFeed is IAaveV4PriceFeed {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    /**
     * @notice The feed for the underlying asset's USD price; address(0) when the rate is USD-quoted
     * @dev Must be a staleness-checking IAaveV4PriceFeed (another of our feeds), never a raw Chainlink
     *      aggregator: _composeUsd trusts its latestAnswer for freshness and does not re-check its age.
     */
    IAaveV4PriceFeed public immutable underlyingUsdFeed;
    /// @notice The decimals of the underlying feed (0 when unset)
    uint8 public immutable underlyingDecimals;
    /// @notice The decimals of the price this feed reports
    uint8 public immutable feedDecimals;
    /// @notice Whether the price snaps to exactly 1 USD when within 1% of it (USD stables only)
    bool public immutable isStableToken;

    string private _description;

    /// @notice Thrown when a price source reports a zero or negative price
    error InvalidPrice();
    /// @notice Thrown when a price source is older than its staleness limit
    error StalePrice();
    /// @notice Thrown when the staleness bound is zero
    error InvalidMaxStaleness();

    constructor(IAaveV4PriceFeed _underlyingUsdFeed, uint8 _feedDecimals, bool _isStableToken, string memory feedDescription) {
        underlyingUsdFeed = _underlyingUsdFeed;
        if (address(_underlyingUsdFeed) != address(0)) {
            underlyingDecimals = _underlyingUsdFeed.decimals();
        }
        feedDecimals = _feedDecimals;
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
     * @dev Composes the reported price from a raw `rate` in `rateDecimals`: scaled straight to feed
     *      decimals when USD-quoted, else multiplied by the underlying USD price and normalized from
     *      (rateDecimals + underlyingDecimals) to feedDecimals. Snaps to 1 USD for stables. Reverts when
     *      the underlying leg is non-positive, or when the scaled price floors to zero (a tiny rate lost
     *      to integer division), so the feed never reports a zero collateral price.
     */
    function _composeUsd(uint256 rate, uint8 rateDecimals) internal view returns (int256) {
        uint256 price;
        if (address(underlyingUsdFeed) == address(0)) {
            price = rate.mulDiv(10 ** feedDecimals, 10 ** rateDecimals);
        } else {
            int256 underlyingAnswer = underlyingUsdFeed.latestAnswer();
            if (underlyingAnswer <= 0) revert InvalidPrice();
            price = rate.mulDiv(underlyingAnswer.toUint256() * 10 ** feedDecimals, 10 ** (rateDecimals + underlyingDecimals));
        }

        price = StablePriceLib.snap(price, isStableToken, feedDecimals);
        if (price == 0) revert InvalidPrice();
        return price.toInt256();
    }
}
