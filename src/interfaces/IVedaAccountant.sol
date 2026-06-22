// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVedaAccountant
 * @notice The part of a Veda accountant the feed reads. getRateSafe returns the vault rate and
 *         reverts when the accountant is paused.
 * @dev MIT mirror of Veda's AccountantWithRateProviders (Se7en-Seas/boring-vault), only what we call.
 * @author ether.fi
 */
interface IVedaAccountant {
    /// @notice The exchange rate in the base asset; reverts if the accountant is paused
    function getRateSafe() external view returns (uint256);

    /// @notice The decimals of the exchange rate
    function decimals() external view returns (uint8);
}
