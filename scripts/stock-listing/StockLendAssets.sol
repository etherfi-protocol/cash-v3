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
}
