// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title QqqxProdConfig
 * @notice Shared address table and parameters for the prod iwQQQx collateral rollout
 *         (follow-up to the cash-mainnet-asset-listing ETH + OP bundles, which list wQQQx and
 *         wire the relay/OFT rails).
 *
 *         The rollout is two Safe bundles plus one EOA deploy, in execution order:
 *           1. DeployQqqxProdFeeds        — EOA: immutable Aave v4 price feeds on OP
 *           2. ListQqqxSummerLend3CP      — Lend Owner Safe (OP): hub + spoke reserve listing
 *           3. ConfigureQqqxCashOP3CP     — Operating Safe (OP): DebtManager collateral,
 *              LendGateway reserve id
 *
 *         Unlike the wSPYx/PAXG rollout there is no retirement bundle: the wQQQx relay leg is
 *         permanent, so iwQQQx keeps reading the OracleSink indefinitely.
 *
 *         Address provenance: iwQQQx/sink/relay from the cash-mainnet-asset-listing ETH + OP
 *         bundles (PR #TBD); Summer Lend instance from the pinned address book
 *         lib/aave-v4/src/etherfi/AaveV4EtherfiCash.sol; the rest from deployments/mainnet.
 */
library QqqxProd {
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev Holds the configurator domain-admin role (400) on the Summer Lend instance AccessManager
    address internal constant LEND_OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

    /// @dev EtherFiShadowOFT on Optimism, deployed by the wQQQx Optimism listing bundle
    ///      (cash-mainnet-asset-listing). CREATE3-predicted; asserted against the live factory.
    address internal constant IWQQQX = 0x3c99d3a81b27583B2E26dbd387C10411f2763516;
    /// @dev Mainnet underlyings — the OracleSink/PriceRelay price key, and the base-asset key
    address internal constant WQQQX_MAINNET = 0x4C1AE29c159838fC1b224636E28E086EB69101f7;
    address internal constant QQQX_MAINNET = 0xa753A7395cAe905Cd615Da0B82A53E0560f250af;
    bytes32 internal constant WQQQX_SALT = 0x1c283c2cba20a91fb5c5885240f0ef30c37d01033a327fbac865c51febc91a46;
    string internal constant IWQQQX_NAME = "EtherFi Wrapped Nasdaq xStock";
    string internal constant IWQQQX_SYMBOL = "iwQQQx";

    /// @dev Chainlink QQQ/USD (24/5) aggregator on Optimism, 8 decimals — the same one the cash
    ///      PriceProviderV2 uses as the QQQx base entry
    address internal constant QQQ_USD_AGGREGATOR = 0xE59148F773705A7231e9E04c8431CDD6EDF197D1;
    address internal constant ORACLE_SINK = 0x7cb68ddc781153d9417E08bAf6A64e801e398d42;
    address internal constant SHADOW_OFT_FACTORY = 0xBD17E3ec1d5c49abe59F64F4bCe1D663fD28d983;

    // Summer Lend prod instance (OP) — from lib/aave-v4/src/etherfi/AaveV4EtherfiCash.sol
    address internal constant HUB_CONFIGURATOR = 0xA39bEf2fD611fb9c5a69D63277b4Af97a30F0dbC;
    address internal constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address internal constant CASH_HUB = 0x66753c4e3fC84f1eD0e3C267C927284E9d90C572;
    address internal constant CASH_SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address internal constant TREASURY_SPOKE = 0x7EB4d25F137868662350603A2863F682287b0768;
    address internal constant IR_STRATEGY = 0x51d07C362f9c4716F96EbEB63DB985EF9D2aCd7C;
    address internal constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;

    /// @dev QQQ/USD is 24/5: 3 days clears the ~65h Friday-close -> Sunday-reopen gap. A US market
    ///      holiday adjacent to a weekend produces a longer gap and the feed reads stale — fail-closed
    ///      on both the cash and lend sides — until reopen.
    uint256 internal constant QQQ_USD_MAX_STALENESS = 3 days;
    /// @dev Max age of the relay's source-chain read of the wQQQx -> QQQx rate. This is the binding
    ///      keeper cadence: tighter than the sink's own 7-day window, and immutable once deployed.
    uint256 internal constant IWQQQX_RATE_MAX_STALENESS = 3 days;
    uint8 internal constant FEED_DECIMALS = 8;

    // DebtManager (100e18 = 100%) — mirrors iwSPYx
    uint80 internal constant DM_IWQQQX_LTV = 73e18;
    uint80 internal constant DM_IWQQQX_LIQ_THRESHOLD = 78e18;
    uint96 internal constant DM_IWQQQX_LIQ_BONUS = 7.5e18;

    // Summer Lend reserve params — mirrors iwSPYx
    uint16 internal constant LEND_IWQQQX_COLLATERAL_FACTOR = 78_00;
    uint32 internal constant LEND_MAX_LIQUIDATION_BONUS = 11_000; // 10% bonus
    uint16 internal constant LEND_LIQUIDATION_FEE = 10_00;
    uint24 internal constant LEND_COLLATERAL_RISK = 0;
    /// @dev Whole tokens, mirroring the OFT hourly rate limit (~$1.44M at listing-time prices).
    ///      Collateral-only, so the draw cap is 0.
    uint40 internal constant LEND_IWQQQX_ADD_CAP = 2000;
}

// ------------------------------------------------------------------ minimal external interfaces
// Local mirrors of the aave-v4 configurator/read surfaces so the 3CP generators compile under the
// default foundry profile (lib/aave-v4 only builds under FOUNDRY_PROFILE=aave-deploy). Field order
// and types are copied verbatim from scripts/wspyx-paxg/WspyxPaxgProdConfig.sol, which itself
// copies verbatim from the lib/aave-v4 pin the prod instance was deployed from.

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

interface ILendGatewayLike {
    function setReserveId(address asset, uint256 reserveId) external;
    function reserveIdOf(address asset) external view returns (uint256);
}

// ------------------------------------------------------------------ rehearsal-path interfaces
// New for this listing (no wSPYx/PAXG equivalent): the Optimism ShadowOFT factory and a reduced
// OracleSink admin surface, used only by _rehearseQqqxRails() to make the Repo A rails exist on a
// fork before they exist on-chain. No `clearPrice` here — unlike PAXG, wQQQx has no retirement path.

interface IShadowOFTFactoryLike {
    function deployShadowOFT(bytes32 salt, string memory name, string memory symbol, uint8 decimals, address delegate) external returns (address);
    function getDeterministicAddress(bytes32 salt) external view returns (address);
    function isShadowOFT(address token) external view returns (bool);
    function SHADOW_OFT_FACTORY_ADMIN_ROLE() external view returns (bytes32);
}

interface IOracleSinkAdminLike {
    function setMaxStaleness(address token, uint64 maxStaleness_) external;
    function maxStaleness(address token) external view returns (uint64);
    function latestRoundData(address token) external view returns (uint80, int256, uint256, uint256, uint80);
}
