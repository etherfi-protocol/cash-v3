// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { IVedaAccountant } from "../interfaces/IVedaAccountant.sol";
import { BaseAaveV4PriceFeed } from "./BaseAaveV4PriceFeed.sol";

/**
 * @title VedaAccountantPriceFeed
 * @dev Implements the Aave v4 price-feed interface and fails closed: latestAnswer reverts on a paused
 *      or stale accountant, a non-positive or reverting underlying, or a zero rate.
 * @author ether.fi
 */
contract VedaAccountantPriceFeed is BaseAaveV4PriceFeed {
    /// @notice The Veda accountant that provides the vault exchange rate
    IVedaAccountant public immutable accountant;
    /// @notice The maximum age in seconds for the Veda rate before it is rejected
    uint256 public immutable rateMaxStaleness;

    /// @notice Thrown when the accountant has paused itself
    error AccountantPaused();

    constructor(IVedaAccountant _accountant, IAaveV4PriceFeed _underlyingUsdFeed, uint8 _feedDecimals, uint256 _rateMaxStaleness, bool _isStableToken, string memory feedDescription) BaseAaveV4PriceFeed(_underlyingUsdFeed, _feedDecimals, _accountant.decimals(), _isStableToken, feedDescription) {
        require(_rateMaxStaleness > 0, InvalidMaxStaleness());
        accountant = _accountant;
        rateMaxStaleness = _rateMaxStaleness;
    }

    /**
     * @notice The token's price: the vault rate, times the underlying USD price when configured
     * @dev Reverts if the accountant is paused or stale, the underlying is not positive or reverts,
     *      or the rate is zero
     */
    function latestAnswer() external view returns (int256) {
        IVedaAccountant.AccountantState memory state = accountant.accountantState();
        if (state.isPaused) revert AccountantPaused();
        if (block.timestamp > state.lastUpdateTimestamp + rateMaxStaleness) revert StalePrice();

        uint256 rate = state.exchangeRate;
        if (rate == 0) revert InvalidPrice();

        return _composeUsd(rate);
    }
}
