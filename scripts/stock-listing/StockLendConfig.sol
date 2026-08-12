// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title StockLendConfig
 * @notice Shared shape for a 4626-wrapped xStock's Summer Lend / DebtManager collateral rollout,
 *         plus the local aave-v4 interface mirrors every generator needs to compile under the
 *         default foundry profile (lib/aave-v4 only builds under FOUNDRY_PROFILE=aave-deploy).
 *
 *         Every such rollout is two Safe bundles plus one EOA deploy, in execution order:
 *           1. Deploy*ProdFeeds       — EOA: immutable Aave v4 price feeds on OP
 *           2. List*SummerLend3CP     — Lend Owner Safe (OP): hub + spoke reserve listing
 *           3. Configure*CashOP3CP    — Operating Safe (OP): DebtManager collateral,
 *              LendGateway reserve id
 *
 *         Scope is 4626-wrapped stocks only (a base stock token that is a PriceProviderV2 price
 *         KEY, never bridged, plus a wrapper that bridges and relays its rate). PAXG does not fit:
 *         it relays a full USD price with no base composition, so folding it into this struct
 *         would produce dead fields and a branchy generator. It stays its own bundle.
 */
struct StockLendAsset {
    address stock; // e.g. QQQx mainnet — the PriceProviderV2 base-entry key
    address wrapper; // e.g. wQQQx mainnet — the OracleSink/PriceRelay price key
    address iToken; // e.g. iwQQQx on Optimism
    address usdAggregator; // Chainlink <STOCK>/USD on Optimism
    // ---- ADDRESS-AFFECTING: these five feed identity strings are baked into the CREATE3 salt
    // and/or the feed's constructor initcode. Changing any of them for an already-deployed asset
    // moves the deployed feed address and therefore the addReserve price source. Never shared
    // across assets, never defaulted.
    string feedSaltPrefix; // e.g. "QqqxProdFeeds." — per asset, salts every feed this asset deploys
    string stockFeedName; // e.g. "QqqUsdFeed"      — CREATE3 salt component
    string wrapperFeedName; // e.g. "IWQqqXUsdFeed" — CREATE3 salt component
    string stockFeedDesc; // e.g. "QQQ / USD"        — ChainlinkPriceFeed constructor arg
    string wrapperFeedDesc; // e.g. "iwQQQx / USD"   — OracleSinkPriceFeed constructor arg
    // ---- refactor-time regression guard: the exact feed addresses this asset deployed to before
    // the struct existed. Zero disables the check (a brand-new asset has no prior address to
    // check against). Asserted in _deployFeeds — see StockFeedDeployer below.
    address expectedStockFeed;
    address expectedWrapperFeed;
    string iTokenName; // rehearsal ShadowOFT deploy
    string iTokenSymbol;
    string feedsJsonStockKey; // e.g. "QQQ"    — summer-lend-feeds.json key
    string feedsJsonWrapperKey; // e.g. "iwQQQx"
    uint256 usdFeedMaxStaleness; // Aave v4 feed leg, e.g. 3 days
    uint256 rateMaxStaleness; // Aave v4 feed leg, relayed rate, e.g. 3 days
    /// @dev cash-mainnet-asset-listing's PriceProviderV2 base-entry staleness for this asset's
    ///      <STOCK>/USD leg. This is the OTHER repo's parameter (its Task A3 mirror), reproduced
    ///      here only so a fork rehearsal can stand in for a bundle this repo does not own or ship.
    ///      NOT the same value as usdFeedMaxStaleness above, which is this repo's own Aave feed leg.
    uint24 cashBaseFeedMaxStaleness;
    uint256 seedRate6dp; // fork-only rehearsal seed, e.g. 1_002_725
    // ---- DebtManager (100e18 = 100%)
    uint80 ltv;
    uint80 liquidationThreshold;
    uint96 liquidationBonus;
    // ---- Summer Lend reserve
    uint16 collateralFactor;
    uint40 addCap;
}

/**
 * @dev Everything a rollout needs that is NOT per-asset: fixed infra addresses, the Summer Lend
 *      prod instance, shared risk-review constants that every collateral-only launch reserve
 *      picks the same value for (mirroring iwSPYx), and the OFT salt derivation.
 */
library LendRails {
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev Holds the configurator domain-admin role (400) on the Summer Lend instance AccessManager
    address internal constant LEND_OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

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

    uint8 internal constant FEED_DECIMALS = 8;

    /// @dev Max age of the OracleSink's own relayed reading before the sink itself considers it
    ///      stale, independent of any per-asset Aave feed staleness above it. Fixed sink config,
    ///      not a per-listing risk parameter, so it is fine to share.
    uint64 internal constant ORACLE_SINK_MAX_STALENESS = 7 days;

    // Summer Lend reserve params — mirrors iwSPYx, shared across every collateral-only launch reserve
    uint32 internal constant LEND_MAX_LIQUIDATION_BONUS = 11_000; // 10% bonus
    uint16 internal constant LEND_LIQUIDATION_FEE = 10_00; // matches every launch reserve
    uint24 internal constant LEND_COLLATERAL_RISK = 0;

    /// @dev Mirrors cash-mainnet-asset-listing's OFT salt scheme exactly: keccak256(abi.encode
    ///      ("EtherFiOFT", wrapper)). Derived, never stored, so it cannot drift from the wrapper
    ///      it keys — this is what the live ShadowOFT factory address is actually keyed by.
    function oftSalt(address wrapper) internal pure returns (bytes32) {
        return keccak256(abi.encode("EtherFiOFT", wrapper));
    }
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
// Used only by _rehearseStockRails() to make the cash-mainnet-asset-listing rails (a ShadowOFT +
// a relayed sink price) exist on a fork before they exist on-chain. No `clearPrice` here — unlike
// PAXG, a 4626-wrapped xStock relay leg has no retirement path.

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
