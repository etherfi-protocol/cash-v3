// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PaxgyCashProd
 * @notice Pins for the cash side of the PAXGy collateral listing on Optimism. The OFT rails, withdraw
 *         whitelist and StargateModule route shipped in 3CP 690, the mainnet top-up route in 691 and the
 *         Summer Lend reserve (id 24) in 698.
 */
library PaxgyCashProd {
    /// @dev Cash operating safe (OP): PRICE_PROVIDER_ADMIN_ROLE, DEBT_MANAGER_ADMIN_ROLE, LEND_GATEWAY_ADMIN_ROLE
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @dev iPAXGy shadow OFT on Optimism (3CP 690), 18 decimals
    address internal constant IPAXGY = 0x5168E0cDeb3f308F47fDF0D9A2E250A2135C3cF5;

    /// @dev Chainlink "PAXGy / Gold Exchange Rate" on Optimism: XAU per PAXGy, 18 decimals, 24h heartbeat
    address internal constant PAXGY_XAU_RATE_FEED = 0xDD12d3De4964eC93F81752c8F2552f053124B180;
    /// @dev Chainlink "XAU / USD" on Optimism, 8 decimals, 20 min heartbeat
    address internal constant XAU_USD_AGGREGATOR = 0x8F7bFb42Bf7421c2b34AAD619be4654bFa7B3B8B;
    /// @dev PriceProviderV2 key carrying XAU / USD as the base asset of iPAXGy (Chainlink Denominations.XAU)
    address internal constant XAU_DENOMINATION = address(959);
    /// @dev Same 7-day bounds the Summer Lend "PAXGy / USD" feed enforces on both legs
    uint24 internal constant PAXGY_XAU_MAX_STALENESS = 7 days;
    uint24 internal constant XAU_USD_MAX_STALENESS = 7 days;

    /// @dev DebtManager config (100e18 = 100%), per risk sign-off
    uint80 internal constant DM_LTV = 67e18;
    uint80 internal constant DM_LIQ_THRESHOLD = 75e18;
    uint96 internal constant DM_LIQ_BONUS = 10e18;

    /// @dev Summer Lend prod instance, from 3CP 698
    address internal constant CASH_SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address internal constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    uint256 internal constant LEND_RESERVE_ID = 24;
    address internal constant LEND_PAXGY_FEED = 0x9B92A2D4468ff3Df8A6Be50Ad043E8a5165459c2;
}
