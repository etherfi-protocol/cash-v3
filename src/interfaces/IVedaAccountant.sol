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
    struct AccountantState {
        address payoutAddress;
        uint96 highwaterMark;
        uint128 feesOwedInBase;
        uint128 totalSharesLastUpdate;
        uint96 exchangeRate;
        uint16 allowedExchangeRateChangeUpper;
        uint16 allowedExchangeRateChangeLower;
        uint64 lastUpdateTimestamp;
        bool isPaused;
        uint24 minimumUpdateDelayInSeconds;
        uint16 platformFee;
        uint16 performanceFee;
    }

    /// @notice The exchange rate in the base asset; reverts if the accountant is paused
    function getRateSafe() external view returns (uint256);

    /// @notice The accountant state, including the last exchange-rate update timestamp
    function accountantState() external view returns (AccountantState memory);

    /// @notice The decimals of the exchange rate
    function decimals() external view returns (uint8);
}
