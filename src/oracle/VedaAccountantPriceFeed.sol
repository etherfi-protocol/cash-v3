// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { IVedaAccountant } from "../interfaces/IVedaAccountant.sol";

/**
 * @title VedaAccountantPriceFeed
 * @notice Prices a Veda receipt token (e.g. eBTC, the Liquid tokens, eUSD, sETHFI) for the Aave v4
 *         oracle. The price is the vault exchange rate times the underlying asset's USD price. The
 *         rate comes from the vault's Veda accountant and the underlying USD price from a Chainlink
 *         feed. One instance is deployed per receipt token.
 * @dev Implements the Aave v4 price-feed interface. The feed fails closed. latestAnswer reverts if
 *      the accountant is paused (getRateSafe), if the Chainlink price is stale or not positive, or
 *      if the rate is zero. A max-age check on the rate itself is a planned follow-up, once the
 *      deployed accountant's state getter is confirmed on a fork.
 * @author ether.fi
 */
contract VedaAccountantPriceFeed is IAaveV4PriceFeed {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice The Veda accountant that provides the vault exchange rate
    IVedaAccountant public immutable accountant;
    /// @notice The Chainlink feed for the underlying asset's USD price, e.g. ETH/USD or BTC/USD
    IAggregatorV3 public immutable underlyingUsdFeed;
    /// @notice The decimals of the exchange rate from the accountant
    uint8 public immutable rateDecimals;
    /// @notice The decimals of the underlying Chainlink feed
    uint8 public immutable underlyingDecimals;
    /// @notice The decimals of the price this feed reports
    uint8 public immutable feedDecimals;
    /// @notice The maximum age in seconds for the underlying Chainlink price before it is rejected
    uint256 public immutable underlyingMaxStaleness;

    string private _description;

    /// @notice Thrown when the underlying Chainlink price is older than underlyingMaxStaleness
    error StalePrice();
    /// @notice Thrown when the rate or the underlying price is zero or negative
    error InvalidPrice();

    constructor(IVedaAccountant _accountant, IAggregatorV3 _underlyingUsdFeed, uint8 _feedDecimals, uint256 _underlyingMaxStaleness, string memory feedDescription) {
        accountant = _accountant;
        underlyingUsdFeed = _underlyingUsdFeed;
        rateDecimals = _accountant.decimals();
        underlyingDecimals = _underlyingUsdFeed.decimals();
        feedDecimals = _feedDecimals;
        underlyingMaxStaleness = _underlyingMaxStaleness;
        _description = feedDescription;
    }

    /**
     * @notice The number of decimals used to represent the price
     * @return The price decimals this feed reports
     */
    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    /**
     * @notice A human-readable description of the feed
     * @return The feed description set at deployment
     */
    function description() external view returns (string memory) {
        return _description;
    }

    /**
     * @notice The latest price for the token, the vault exchange rate times the underlying USD price
     * @dev Reverts if the accountant is paused, the underlying price is stale or not positive, or the rate is zero
     * @return The price expressed with decimals() precision
     */
    function latestAnswer() external view returns (int256) {
        // Exchange rate in the base asset. Reverts if the accountant paused itself on a bad or too-frequent update
        uint256 rate = accountant.getRateSafe();
        if (rate == 0) revert InvalidPrice();

        // Underlying asset USD price from Chainlink, with validity and staleness checks.
        (, int256 answer,, uint256 updatedAt,) = underlyingUsdFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp > updatedAt + underlyingMaxStaleness) revert StalePrice();

        // price = rate * underlyingPrice, normalized from (rateDecimals + underlyingDecimals) to feedDecimals
        uint256 price = rate.mulDiv(answer.toUint256() * 10 ** feedDecimals, 10 ** (rateDecimals + underlyingDecimals));

        return price.toInt256();
    }
}
