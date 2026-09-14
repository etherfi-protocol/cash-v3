// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev One collateral stock moving from the Ethereum-locked mirror token to Backed's OP wrapper.
struct MigratedStock {
    string symbol; // e.g. "SPYx"
    address stock; // raw Backed token on OP; also the PriceProviderV2 base-entry key for <STOCK>/USD
    address wrapper; // Backed wrapperV2 on OP, the new collateral
    address iToken; // the OP mirror token being retired
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

    function all() internal pure returns (MigratedStock[] memory) {
        MigratedStock[] memory stocks = new MigratedStock[](3);
        stocks[0] = MigratedStock({ symbol: "SPYx", stock: 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48, wrapper: 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, iToken: 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c, oldReserveId: 19, stockUsdLeg: 0xf41eBb842D8e2e2ea818BC6f27497fEF97FAe68F, wrapperFeedName: "WSpyxUsdFeed", wrapperFeedDesc: "wSPYx / USD" });
        stocks[1] = MigratedStock({ symbol: "QQQx", stock: 0xa753A7395cAe905Cd615Da0B82A53E0560f250af, wrapper: 0x4C1AE29c159838fC1b224636E28E086EB69101f7, iToken: 0x3c99d3a81b27583B2E26dbd387C10411f2763516, oldReserveId: 21, stockUsdLeg: 0x2cD17B00f5E2C0613323C2fdB9709d54d958AFEb, wrapperFeedName: "WQqqxUsdFeed", wrapperFeedDesc: "wQQQx / USD" });
        stocks[2] = MigratedStock({ symbol: "TBLLx", stock: 0x4cbf89ED7Bb30b8a860fa86d3c96E9c72931299b, wrapper: 0x461b25b99606Fe169D6F0dD6816650eF6536403E, iToken: 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387, oldReserveId: 22, stockUsdLeg: 0xeb1A9eBBe265E3f0Bd69d0eF27536cD1DC77Bc73, wrapperFeedName: "WTbllxUsdFeed", wrapperFeedDesc: "wTBLLx / USD" });
        return stocks;
    }
}

/// @dev The configurator calls this migration adds to the stock-listing mirrors (same role gating: 400
///      for the price source, 402 for the freeze, both held by the Lend Owner Safe).
interface ISpokeConfiguratorMigrationLike {
    function updateReservePriceSource(address spoke, uint256 reserveId, address priceSource) external;
    function freezeReserve(address spoke, uint256 reserveId) external;
}
