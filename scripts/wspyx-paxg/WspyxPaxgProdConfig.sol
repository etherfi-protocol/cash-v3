// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title WspyxPaxgProdConfig
 * @notice Shared address table and parameters for the prod wSPYx + PAXG collateral rollout
 *         (follow-up to 3CPs 621/622, which listed the assets and wired the relay/OFT rails).
 *
 *         The rollout is three Safe bundles plus one EOA deploy, in execution order:
 *           1. DeployWspyxPaxgProdFeeds        — EOA: immutable Aave v4 price feeds on OP
 *           2. ListWspyxPaxgSummerLend3CP      — Lend Owner Safe (OP): hub + spoke reserve listings
 *           3. ConfigureWspyxPaxgCashOP3CP     — Operating Safe (OP): iPAXG Chainlink repoint,
 *              PAXG sink delisting, DebtManager collateral, LendGateway reserve ids
 *           4. RemovePaxgWspyxEthereum3CP      — Operating Safe (ETH): PAXG relay unsubscribe +
 *              relay-provider config removal, wSPYx + PAXG dropped from the TradingLens
 *
 *         Address provenance: iTOKENs/sink/relay from the 3CP 621/622 bundles
 *         (cash-mainnet-asset-listing, PR #18); Summer Lend instance from the pinned address book
 *         lib/aave-v4/src/etherfi/AaveV4EtherfiCash.sol; the rest from deployments/mainnet.
 */
library WspyxPaxgProd {
    // ---------------------------------------------------------------- Safes
    /// @dev Cash operating safe (ETH + OP)
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev Summer Lend Owner Safe — holds the configurator domain-admin role (400) on the
    ///      instance AccessManager (see AaveV4EtherfiCash.OWNER_SAFE)
    address internal constant LEND_OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

    // ---------------------------------------------------------------- tokens
    /// @dev EtherFiShadowOFTs on Optimism, deployed by 3CP 622 (18 decimals)
    address internal constant IWSPYX = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;
    address internal constant IPAXG = 0x41a7f2bb9789199654c206f09392674c1Af6676c;
    /// @dev Mainnet underlyings — the OracleSink/PriceRelay price keys and the ETH-side registry
    ///      entries (the relay ships mainnet token addresses)
    address internal constant WSPYX_MAINNET = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address internal constant PAXG_MAINNET = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    // ---------------------------------------------------------------- oracles (OP)
    /// @dev Chainlink PAXG/USD aggregator on Optimism, 8 decimals, ~24h heartbeat
    address internal constant PAXG_USD_AGGREGATOR = 0x977CD3bC66A1FA9Fb22F9BEAA966E06996f70512;
    /// @dev Chainlink SPY/USD (24/5) aggregator on Optimism, 8 decimals — same one 3CP 622 put in
    ///      PriceProviderV2 as the SPYx base entry
    address internal constant SPY_USD_AGGREGATOR = 0x5F77134CfAA7DB2906649Ca21C50dA54daE9291d;
    /// @dev Prod OracleSink on Optimism (3CP 622), keyed by MAINNET token addresses
    address internal constant ORACLE_SINK = 0x7cb68ddc781153d9417E08bAf6A64e801e398d42;

    // ---------------------------------------------------------------- ETH relay stack (3CP 621)
    address internal constant PRICE_RELAY = 0xc4D666B44daa8D6d12b84875384e08BaE52aFE19;
    /// @dev The PriceProviderV2 instance the PriceRelay reads its sources from ("RelayPriceProvider")
    address internal constant RELAY_PRICE_PROVIDER = 0x12224C84783c66885cF838fcb189918d23B17f66;

    // ---------------------------------------------------------------- Summer Lend prod instance (OP)
    // From lib/aave-v4/src/etherfi/AaveV4EtherfiCash.sol (pinned address book, verified on-chain)
    address internal constant HUB_CONFIGURATOR = 0xA39bEf2fD611fb9c5a69D63277b4Af97a30F0dbC;
    address internal constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address internal constant CASH_HUB = 0x66753c4e3fC84f1eD0e3C267C927284E9d90C572;
    address internal constant CASH_SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address internal constant TREASURY_SPOKE = 0x7EB4d25F137868662350603A2863F682287b0768;
    address internal constant IR_STRATEGY = 0x51d07C362f9c4716F96EbEB63DB985EF9D2aCd7C;
    address internal constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;

    // ---------------------------------------------------------------- staleness bounds
    /// @dev SPY/USD is 24/5: 3 days clears the ~65h Friday-close -> Sunday-reopen gap. NOTE: a US
    ///      market holiday adjacent to a weekend produces a longer gap and the feed will read stale
    ///      until the market reopens (fail-closed on both the cash and lend sides).
    uint256 internal constant SPY_USD_MAX_STALENESS = 3 days;
    /// @dev Max age of the relay's source-chain read of the wSPYx -> SPYx rate; requires the relay
    ///      keeper to poke at least every 3 days (the sink's own wSPYx window from 622 is 7 days)
    uint256 internal constant IWSPYX_RATE_MAX_STALENESS = 3 days;
    /// @dev PAXG/USD heartbeats ~24h; 3 days per risk sign-off (raised from 1 day, aligning with
    ///      the SPY-side bounds; the 1-day PaxgUsdFeed at 0xDc77fb41…03Be is superseded and unused)
    uint256 internal constant PAXG_USD_MAX_STALENESS = 3 days;

    uint8 internal constant FEED_DECIMALS = 8;

    // ---------------------------------------------------------------- DebtManager configs (100e18 = 100%)
    uint80 internal constant DM_IWSPYX_LTV = 73e18;
    uint80 internal constant DM_IWSPYX_LIQ_THRESHOLD = 78e18;
    uint96 internal constant DM_IWSPYX_LIQ_BONUS = 7.5e18;

    uint80 internal constant DM_IPAXG_LTV = 75e18;
    uint80 internal constant DM_IPAXG_LIQ_THRESHOLD = 80e18;
    uint96 internal constant DM_IPAXG_LIQ_BONUS = 6e18;

    // ---------------------------------------------------------------- Summer Lend reserve params
    // Per the risk sheet for this listing: CF 78% / 80%, max liquidation bonus 10%
    // (100_00 bps = 0% bonus), liquidation fee 10%, collateral risk 0 bps, borrowable no.
    uint16 internal constant LEND_IWSPYX_COLLATERAL_FACTOR = 78_00;
    uint16 internal constant LEND_IPAXG_COLLATERAL_FACTOR = 80_00;
    uint32 internal constant LEND_MAX_LIQUIDATION_BONUS = 11_000; // 10% bonus
    uint16 internal constant LEND_LIQUIDATION_FEE = 10_00; // matches every launch reserve
    uint24 internal constant LEND_COLLATERAL_RISK = 0;

    /// @dev Hub add caps in whole tokens, mirroring the 621/622 OFT hourly rate limits
    ///      (~$1.5M per asset at listing-time prices). Collateral-only, so draw caps are 0.
    uint40 internal constant LEND_IWSPYX_ADD_CAP = 2000;
    uint40 internal constant LEND_IPAXG_ADD_CAP = 300;
}

// ------------------------------------------------------------------ minimal external interfaces
// Local mirrors of the aave-v4 configurator/read surfaces so the 3CP generators compile under the
// default foundry profile (lib/aave-v4 only builds under FOUNDRY_PROFILE=aave-deploy). Field order
// and types are copied verbatim from the lib/aave-v4 pin the prod instance was deployed from.

struct SpokeConfigLike {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

struct InterestRateDataLike {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

struct ReserveConfigLike {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
}

struct DynamicReserveConfigLike {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
}

/// @dev ISpoke.Reserve with the two non-elementary field types (IHubBase, the uint8-backed
///      ReserveFlags user type) replaced by their ABI equivalents
struct ReserveLike {
    address underlying;
    address hub;
    uint16 assetId;
    uint8 decimals;
    uint24 collateralRisk;
    uint8 flags;
    uint32 dynamicConfigKey;
}

interface IHubConfiguratorLike {
    function addAsset(address hub, address underlying, address feeReceiver, uint256 liquidityFee, address irStrategy, bytes calldata irData) external returns (uint256);
    function addSpoke(address hub, address spoke, uint256 assetId, SpokeConfigLike calldata config) external;
}

interface ISpokeConfiguratorLike {
    function addReserve(address spoke, address hub, uint256 assetId, address priceSource, ReserveConfigLike calldata config, DynamicReserveConfigLike calldata dynamicConfig) external returns (uint256);
}

interface IHubLike {
    function getAssetCount() external view returns (uint256);
    function getSpokeConfig(uint256 assetId, address spoke) external view returns (SpokeConfigLike memory);
}

interface ISpokeLike {
    function getReserveCount() external view returns (uint256);
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);
    function getReserve(uint256 reserveId) external view returns (ReserveLike memory);
    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfigLike memory);
    function getDynamicReserveConfig(uint256 reserveId, uint32 dynamicConfigKey) external view returns (DynamicReserveConfigLike memory);
}

interface IAaveOracleLike {
    function getReserveSource(uint256 reserveId) external view returns (address);
    function getReservePrice(uint256 reserveId) external view returns (uint256);
}

interface IOracleSinkAdminLike {
    function setMaxStaleness(address token, uint64 maxStaleness_) external;
    function clearPrice(address token) external;
    function maxStaleness(address token) external view returns (uint64);
    function latestRoundData(address token) external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IPriceRelayLike {
    function unsubscribe(address token) external;
    function subscribedTokens() external view returns (address[] memory);
}

interface IRelayPriceProviderLike {
    function removeTokenConfig(address token) external;
    function price(address token) external view returns (uint256);
}

interface ITradingLensLike {
    function removeSupportedToken(address token) external;
    function isSupportedToken(address token) external view returns (bool);
}

interface ILendGatewayLike {
    function setReserveId(address asset, uint256 reserveId) external;
    function reserveIdOf(address asset) external view returns (uint256);
}
