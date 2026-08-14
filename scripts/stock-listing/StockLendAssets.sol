// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StockLendAsset } from "./StockLendConfig.sol";

/**
 * @title StockLendAssets
 * @notice Per-asset StockLendAsset entries for the xStock Summer Lend / DebtManager collateral
 *         rollout. QQQx is the first.
 */
library StockLendAssets {
    /**
     * @notice iwQQQx prod collateral rollout parameters (follow-up to the
     *         cash-mainnet-asset-listing ETH + OP bundles, which list wQQQx and wire the
     *         relay/OFT rails).
     *
     *         Unlike the wSPYx/PAXG rollout there is no retirement bundle for this asset: the
     *         wQQQx relay leg is permanent, so iwQQQx keeps reading the OracleSink indefinitely.
     *
     *         Address provenance: iwQQQx/sink/relay from the cash-mainnet-asset-listing ETH + OP
     *         bundles (PR #TBD); Summer Lend instance from the pinned address book
     *         lib/aave-v4/src/etherfi/AaveV4EtherfiCash.sol; the rest from deployments/mainnet.
     *
     *         `expectedStockFeed`/`expectedWrapperFeed` are the CREATE3 addresses this asset's
     *         feeds actually deployed to (QqqUsdFeed / IWQqqXUsdFeed) — asserted in
     *         StockFeedDeployer._deployFeeds as a refactor-time regression guard against a typo
     *         in feedSaltPrefix/stockFeedName/wrapperFeedName/stockFeedDesc/wrapperFeedDesc
     *         silently deploying a different feed at a different address.
     */
    function wqqqx() internal pure returns (StockLendAsset memory) {
        return StockLendAsset({
            stock: 0xa753A7395cAe905Cd615Da0B82A53E0560f250af,
            wrapper: 0x4C1AE29c159838fC1b224636E28E086EB69101f7,
            iToken: 0x3c99d3a81b27583B2E26dbd387C10411f2763516,
            usdAggregator: 0xE59148F773705A7231e9E04c8431CDD6EDF197D1,
            feedSaltPrefix: "QqqxProdFeeds.",
            stockFeedName: "QqqUsdFeed",
            wrapperFeedName: "IWQqqXUsdFeed",
            stockFeedDesc: "QQQ / USD",
            wrapperFeedDesc: "iwQQQx / USD",
            expectedStockFeed: 0x459E1D5e587eB81bA25C6AA1e817e40bd36fb2F4,
            expectedWrapperFeed: 0xb5f61BDfCa60c02d13377d4386288FE143b9d6bE,
            iTokenName: "EtherFi Wrapped Nasdaq xStock",
            iTokenSymbol: "iwQQQx",
            feedsJsonStockKey: "QQQ",
            feedsJsonWrapperKey: "iwQQQx",
            /// @dev QQQ/USD is 24/5: 3 days clears the ~65h Friday-close -> Sunday-reopen gap. A US
            ///      market holiday adjacent to a weekend produces a longer gap and the feed reads
            ///      stale — fail-closed on both the cash and lend sides — until reopen.
            usdFeedMaxStaleness: 3 days,
            /// @dev Max age of the relay's source-chain read of the wQQQx -> QQQx rate. This is the
            ///      binding keeper cadence: tighter than the sink's own 7-day window, and immutable
            ///      once deployed.
            rateMaxStaleness: 3 days,
            cashBaseFeedMaxStaleness: 78 hours,
            seedRate6dp: 1_002_725, // live convertToAssets(1e18) at authoring time, normalised to 6 decimals
            // DebtManager — mirrors iwSPYx
            ltv: 73e18,
            liquidationThreshold: 78e18,
            liquidationBonus: 7.5e18,
            // Summer Lend reserve — mirrors iwSPYx
            collateralFactor: 78_00,
            /// @dev Whole tokens, mirroring the OFT hourly rate limit (~$1.44M at listing-time
            ///      prices). Collateral-only, so the draw cap is 0.
            addCap: 2000
        });
    }

    /**
     * @notice iwTBLLx prod collateral rollout parameters (follow-up to the
     *         cash-mainnet-asset-listing ETH + OP bundles, which list wTBLLx and wire the
     *         relay/OFT rails).
     *
     *         Same shape as iwQQQx: the USD leg is a Chainlink aggregator on Optimism, Ethereum
     *         only relays the 4626 rate, and the wTBLLx relay leg is permanent — no retirement
     *         bundle, iwTBLLx reads the OracleSink indefinitely.
     *
     *         Address provenance verified on-chain 2026-08-12: wrapper.asset() == stock, both 18
     *         decimals; usdAggregator.description() == "TBLL / USD", 8 decimals, reading $105.735.
     *         iToken is the CREATE3 ShadowOFT address from the listing repo's StockRails.oftSalt,
     *         derived against the live factory (derivation validated by reproducing iwQQQx's
     *         known address exactly).
     *
     *         Brand-new asset, so expectedStockFeed/expectedWrapperFeed are address(0) — there is
     *         no prior deployment to regression-check the five identity strings against. Fill them
     *         in from the DeployTbllxProdFeeds broadcast once it lands.
     *
     *         NOTE: wTBLLx totalSupply is 0 — nothing has been wrapped yet. The Backed wrapper is
     *         rate-based rather than share-accounted, so convertToAssets still returns a real rate,
     *         but there is no wrapped float for liquidation depth until deposits begin.
     */
    function wtbllx() internal pure returns (StockLendAsset memory) {
        return StockLendAsset({
            stock: 0x4cbf89ED7Bb30b8a860fa86d3c96E9c72931299b,
            wrapper: 0x461b25b99606Fe169D6F0dD6816650eF6536403E,
            iToken: 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387,
            usdAggregator: 0x6D94824F8c4F5a168913669B9bD9071fAb39BFD2,
            feedSaltPrefix: "TbllxProdFeeds.",
            stockFeedName: "TbllUsdFeed",
            wrapperFeedName: "IWTbllXUsdFeed",
            stockFeedDesc: "TBLL / USD",
            wrapperFeedDesc: "iwTBLLx / USD",
            /// @dev Filled in from the DeployTbllxProdFeeds CREATE3 prediction (dry run,
            ///      2026-08-12) rather than left at address(0). The addresses are deterministic,
            ///      so pinning them now turns on the identity-string regression guard immediately
            ///      instead of after the broadcast — a typo in any of the five strings above
            ///      moves the feed and fails loudly in StockFeedDeployer._deployFeeds.
            expectedStockFeed: 0x1A74F66b6CF21b582C316398925b24D3D04C8C7D,
            expectedWrapperFeed: 0x1cee92F999D536320aFb740b2ea5318C45d9C93B,
            iTokenName: "EtherFi Wrapped TBLL xStock",
            iTokenSymbol: "iwTBLLx",
            feedsJsonStockKey: "TBLL",
            feedsJsonWrapperKey: "iwTBLLx",
            /// @dev TBLL is a US-listed ETF, so its feed is 24/5 exactly like QQQ: 3 days clears
            ///      the ~65h Friday-close -> Sunday-reopen gap. A US market holiday adjacent to a
            ///      weekend produces a longer gap and the feed reads stale — fail-closed on both
            ///      the cash and lend sides — until reopen.
            usdFeedMaxStaleness: 3 days,
            /// @dev Max age of the relay's source-chain read of the wTBLLx -> TBLLx rate. This is
            ///      the binding keeper cadence: tighter than the sink's own 7-day window, and
            ///      immutable once deployed.
            rateMaxStaleness: 3 days,
            cashBaseFeedMaxStaleness: 78 hours,
            seedRate6dp: 1_016_771, // live convertToAssets(1e18) at authoring time, normalised to 6 decimals
            // Risk-signed-off 2026-08-12. TBLLx is a 1-3 month T-bill ETF, so it carries a wider
            // LTV -> LT buffer (10pts vs iwQQQx's 5) on a higher threshold, and the DebtManager
            // bonus is raised to match the Summer Lend max liquidation bonus exactly.
            // DebtManager
            ltv: 70e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 10e18,
            // Summer Lend reserve. collateralFactor tracks the DebtManager liquidationThreshold,
            // as it does for iwQQQx/iwSPYx. maxLiquidationBonus (10%), liquidationFee (10%),
            // collateralRisk (0bps) and borrowable (no) are shared launch-reserve constants on
            // LendRails and already match this asset's sign-off.
            collateralFactor: 80_00,
            /// @dev Whole tokens: ~$2.11M at listing-time prices. Sized independently of the OFT
            ///      hourly rate limit (15,000/hr). Collateral-only, so the draw cap is 0.
            addCap: 20000
        });
    }
}
