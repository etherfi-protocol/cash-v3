// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { IVedaAccountant } from "../interfaces/IVedaAccountant.sol";
import { StablePriceLib } from "./StablePriceLib.sol";

/**
 * @title VedaAccountantPriceFeed
 * @dev Implements the Aave v4 price-feed interface and fails closed: latestAnswer reverts on a paused
 *      or stale accountant, a non-positive or reverting underlying, or a zero rate.
 * @author ether.fi
 */
contract VedaAccountantPriceFeed is IAaveV4PriceFeed {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice The Veda accountant that provides the vault exchange rate
    IVedaAccountant public immutable accountant;
    /// @notice The feed for the underlying asset's USD price; address(0) when the rate is USD-quoted
    IAaveV4PriceFeed public immutable underlyingUsdFeed;
    /// @notice The decimals of the exchange rate from the accountant
    uint8 public immutable rateDecimals;
    /// @notice The decimals of the underlying feed (0 when unset)
    uint8 public immutable underlyingDecimals;
    /// @notice The decimals of the price this feed reports
    uint8 public immutable feedDecimals;
    /// @notice The maximum age in seconds for the Veda rate before it is rejected
    uint256 public immutable rateMaxStaleness;
    /// @notice Whether the price snaps to exactly 1 USD when within 1% of it (USD stables only)
    bool public immutable isStableToken;
    string private _description;

    /// @notice Thrown when either price source is older than its staleness limit
    error StalePrice();
    /// @notice Thrown when the rate or the underlying price is zero or negative
    error InvalidPrice();

    constructor(IVedaAccountant _accountant, IAaveV4PriceFeed _underlyingUsdFeed, uint8 _feedDecimals, uint256 _rateMaxStaleness, bool _isStableToken, string memory feedDescription) {

        accountant = _accountant;
        underlyingUsdFeed = _underlyingUsdFeed;
        rateDecimals = _accountant.decimals();
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
     * @notice The token's price: the vault rate, times the underlying USD price when configured
     * @dev Reverts if the accountant is paused or stale, the underlying is not positive or reverts,
     *      or the rate is zero
     */
    function latestAnswer() external view returns (int256) {
        IVedaAccountant.AccountantState memory state = accountant.accountantState();
        if (block.timestamp > state.lastUpdateTimestamp + rateMaxStaleness) revert StalePrice();

        // Vault rate; reverts if the accountant paused itself.
        uint256 rate = accountant.getRateSafe();
        if (rate == 0) revert InvalidPrice();

        if (address(underlyingUsdFeed) == address(0)) {
            return StablePriceLib.snap(rate.mulDiv(10 ** feedDecimals, 10 ** rateDecimals), isStableToken, feedDecimals).toInt256();
        }

        int256 answer = underlyingUsdFeed.latestAnswer();
        if (answer <= 0) revert InvalidPrice();

        // price = rate * underlyingPrice, normalized from (rateDecimals + underlyingDecimals) to feedDecimals
        uint256 price = rate.mulDiv(answer.toUint256() * 10 ** feedDecimals, 10 ** (rateDecimals + underlyingDecimals));

        return StablePriceLib.snap(price, isStableToken, feedDecimals).toInt256();
    }
}
