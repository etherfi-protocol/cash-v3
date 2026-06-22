// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAaveV4PriceFeed
 * @notice Minimal price-feed interface an asset's price source must implement to be read by the
 *         Aave v4 AaveOracle. Our receipt-token price adapters (weETH, eBTC, Liquid tokens) implement
 *         this so those tokens can be priced on the ether.fi Aave instance and used as collateral.
 * @dev Hand-written MIT mirror of aave-v4 src/spoke/interfaces/IPriceFeed.sol, which is BUSL licensed.
 *      We declare only the ABI we call rather than vendoring BUSL source, matching this repo's existing
 *      IAavePoolV3 pattern. Signatures verified against aave/aave-v4.
 * @author ether.fi
 */
interface IAaveV4PriceFeed {
    /**
     * @notice The number of decimals used to represent the price
     * @return The number of decimals
     */
    function decimals() external view returns (uint8);

    /**
     * @notice A human-readable description of the feed
     * @return The feed description
     */
    function description() external view returns (string memory);

    /**
     * @notice The latest price, expressed with decimals() precision
     * @return The latest price
     */
    function latestAnswer() external view returns (int256);
}
