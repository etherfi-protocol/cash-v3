// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVedaAccountant
 * @notice The part of a Veda AccountantWithRateProviders that the price feed reads. getRateSafe
 *         returns the vault exchange rate and reverts when the accountant has paused itself, which
 *         it does after a rate update that is out of bounds or too frequent.
 * @dev Hand-written MIT mirror of Veda's AccountantWithRateProviders (Se7en-Seas/boring-vault).
 *      Declares only what the feed calls. Verified against that source.
 * @author ether.fi
 */
interface IVedaAccountant {
    /**
     * @notice The current exchange rate in the base asset, reverting if the accountant is paused
     * @return The exchange rate in the base asset
     */
    function getRateSafe() external view returns (uint256);

    /**
     * @notice The number of decimals of the exchange rate returned by getRateSafe
     * @return The exchange rate decimals
     */
    function decimals() external view returns (uint8);
}
