// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev One collateral stock moving from the Ethereum-locked mirror token to Backed's OP wrapper.
struct MigratedStock {
    string symbol; // e.g. "SPYx"
    address stock; // raw Backed token on OP; also the PriceProviderV2 base-entry key for <STOCK>/USD
    address wrapper; // Backed wrapperV2 on OP, the new collateral
    address iToken; // the OP mirror token being retired; also the ShadowOFT to pause
    address adapter; // the Ethereum OFT adapter holding the wrapped collateral
    uint256 oldReserveId; // the mirror token's live Summer Lend reserve
    address stockUsdLeg; // the live <STOCK>/USD IAaveV4PriceFeed the old reserve already composes on
    string wrapperFeedName; // CREATE3 salt component
    string wrapperFeedDesc; // ERC4626RatePriceFeed constructor arg
}

/**
 * @dev The three stocks, their live rails, and the shared feed identity strings. The feed names and
 *      descriptions are baked into CREATE3 salts and initcode, so changing one moves the deployed
 *      address.
 */
library StockMigration {
    string internal constant FEED_SALT_PREFIX = "StockMigrationFeeds.";
    string internal constant ONE_WEI_8_NAME = "OneWeiUsdFeed8";
    string internal constant ONE_WEI_8_DESC = "placeholder 1 wei / USD (8 dec)";
    string internal constant ONE_UNIT_6_NAME = "OneUnitUsdFeed6";
    string internal constant ONE_UNIT_6_DESC = "placeholder 1 unit / USD (6 dec)";

    /// @dev Backed's CCIP bridge, same address on Ethereum and Optimism, and CCIP's selector for Optimism.
    address internal constant BACKED_BRIDGE = 0x9eC0e4A4c411493773E01e2ABF4D42395788846b;
    uint64 internal constant OP_CHAIN_SELECTOR = 3_734_403_246_176_062_136;
    /// @dev The Operating Safe exists at the same address on both chains; it is the OFT adapters' owner, the
    ///      PAUSER and UNPAUSER on both RoleRegistries, and the recipient of the bridged stock on Optimism.
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev Summer Lend's 24h timelock, sole holder of the hub (200) and spoke (400) configurator roles, and the
    ///      3-of-6 Timelock Safe that proposes, executes and cancels on it.
    address internal constant LEND_TIMELOCK = 0xbaCa0cD6B69Eef3257e2D122b22ddEE8AeE5e283;
    address internal constant TIMELOCK_SAFE = 0xd442635bc9bF83E21bBA8B65e224F5Db6a011166;
    bytes32 internal constant LIST_SALT = keccak256("StockMigration.ListWrappers");
    bytes32 internal constant FLIP_SALT = keccak256("StockMigration.FlipPriceSources");

    function all() internal pure returns (MigratedStock[] memory) {
        MigratedStock[] memory stocks = new MigratedStock[](3);
        stocks[0] = MigratedStock({ symbol: "SPYx", stock: 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48, wrapper: 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, iToken: 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c, adapter: 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318, oldReserveId: 19, stockUsdLeg: 0xf41eBb842D8e2e2ea818BC6f27497fEF97FAe68F, wrapperFeedName: "WSpyxUsdFeed", wrapperFeedDesc: "wSPYx / USD" });
        stocks[1] = MigratedStock({ symbol: "QQQx", stock: 0xa753A7395cAe905Cd615Da0B82A53E0560f250af, wrapper: 0x4C1AE29c159838fC1b224636E28E086EB69101f7, iToken: 0x3c99d3a81b27583B2E26dbd387C10411f2763516, adapter: 0xD33685E92f079E05F7e25a5F14e68e44eD53bBC5, oldReserveId: 21, stockUsdLeg: 0x2cD17B00f5E2C0613323C2fdB9709d54d958AFEb, wrapperFeedName: "WQqqxUsdFeed", wrapperFeedDesc: "wQQQx / USD" });
        stocks[2] = MigratedStock({ symbol: "TBLLx", stock: 0x4cbf89ED7Bb30b8a860fa86d3c96E9c72931299b, wrapper: 0x461b25b99606Fe169D6F0dD6816650eF6536403E, iToken: 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387, adapter: 0x8C03Bba46607F0e1bd51c6860293040f0477A1D0, oldReserveId: 22, stockUsdLeg: 0xeb1A9eBBe265E3f0Bd69d0eF27536cD1DC77Bc73, wrapperFeedName: "WTbllxUsdFeed", wrapperFeedDesc: "wTBLLx / USD" });
        return stocks;
    }
}

/// @dev The configurator calls this migration adds to the stock-listing mirrors (role gating: 400 for the
///      price source, held by the lend timelock; 403 for the pause flag and 402 for the freeze, held by the
///      Lend Owner Safe).
interface ISpokeConfiguratorMigrationLike {
    function updateReservePriceSource(address spoke, uint256 reserveId, address priceSource) external;
    function updatePaused(address spoke, uint256 reserveId, bool paused) external;
    function freezeReserve(address spoke, uint256 reserveId) external;
}

/// @dev OpenZeppelin TimelockController, the batch surface the Timelock Safe drives.
interface ILendTimelock {
    function scheduleBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt, uint256 delay) external;
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt) external payable;
    function hashOperationBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt) external pure returns (bytes32);
    function isOperation(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
    function getTimestamp(bytes32 id) external view returns (uint256);
    function getMinDelay() external view returns (uint256);
}

/// @dev The two OFT bridge contracts (Ethereum adapter, Optimism shadow) share this pause surface.
interface IPausableBridge {
    function pauseBridge() external;
    function unpauseBridge() external;
    function paused() external view returns (bool);
    function sweepUnderlying(address to) external;
    function owner() external view returns (address);
}

/// @dev UpgradeableProxy-based cash contracts and the recovery modules.
interface IPausable {
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

interface ITopUpFactoryLike {
    struct TokenConfig {
        address bridgeAdapter;
        address recipientOnDestChain;
        uint96 maxSlippageInBps;
        bytes additionalData;
    }

    function removeTokenConfig(address[] calldata tokens, uint256[] calldata chainIds) external;
    function getTokenConfig(address token, uint256 destChainId) external view returns (TokenConfig memory);
}

interface IBackedCCIPBridge {
    function send(uint64 destinationChainSelector, bytes32 tokenReceiver, address token, uint256 amount, bytes calldata chainSpecificArgs) external payable returns (bytes32);
    function getDeliveryFeeCost(uint64 destinationChainSelector, bytes32 tokenReceiver, address token, uint256 amount, bytes calldata chainSpecificArgs) external view returns (uint256);
    function tokenIds(address token) external view returns (uint64);
    function allowlistedDestinationChains(uint64 selector) external view returns (bytes32);
    function paused() external view returns (bool);
}
