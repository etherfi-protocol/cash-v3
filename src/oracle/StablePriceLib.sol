// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Stable-price handling shared by the Aave v4 price feeds, mirroring PriceProviderV2.
library StablePriceLib {
    /// @dev Snaps a USD-stable price to exactly 1 USD when it is within 1% of it; non-stables pass through.
    function snap(uint256 price, bool isStableToken, uint8 feedDecimals) internal pure returns (uint256) {
        if (!isStableToken) return price;
        uint256 stablePrice = 10 ** feedDecimals;
        uint256 maxDeviation = stablePrice / 100;
        if (price > stablePrice - maxDeviation && price < stablePrice + maxDeviation) return stablePrice;
        return price;
    }
}
