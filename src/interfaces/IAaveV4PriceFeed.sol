// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAaveV4PriceFeed
 * @notice Minimal price-feed interface a price source implements to be read by the Aave v4 AaveOracle.
 *         Our receipt-token feeds implement it so those tokens can be Aave collateral.
 * @dev MIT mirror of aave-v4 src/spoke/interfaces/IPriceFeed.sol (BUSL); we declare only the ABI we
 *      call rather than vendoring BUSL source. Verified against aave/aave-v4.
 * @author ether.fi
 */
interface IAaveV4PriceFeed {
    /// @notice The number of decimals used to represent the price
    function decimals() external view returns (uint8);

    /// @notice A human-readable description of the feed
    function description() external view returns (string memory);

    /// @notice The latest price, expressed with decimals() precision
    function latestAnswer() external view returns (int256);
}
