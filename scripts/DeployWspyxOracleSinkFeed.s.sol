// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { IOracleSink } from "../src/interfaces/IOracleSink.sol";
import { ChainlinkPriceFeed } from "../src/oracle/ChainlinkPriceFeed.sol";
import { OracleSinkPriceFeed } from "../src/oracle/OracleSinkPriceFeed.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployWspyxOracleSinkFeed
 * @notice Deploys the iwSPYx/USD price feed pair for the Aave v4 TEST instance on Optimism,
 *         composing the two halves of the wSPYx split price (see cash-mainnet-asset-listing
 *         ConfigureWspyxOracle*):
 *           1. SPY/USD: a staleness-checked ChainlinkPriceFeed over the 24/5 Chainlink aggregator.
 *              Its staleness must span the Friday-close -> Sunday-reopen gap (78h default there).
 *           2. iwSPYx/USD: an OracleSinkPriceFeed over the dev OracleSink, keyed by the MAINNET
 *              wSPYx address (the relay ships mainnet token addresses), whose relayed value is the
 *              wSPYx -> SPYx rate (6 decimals, moves only at dividend/fee events), composed on the
 *              SPY/USD leg (1 SPYx tracks 1 SPY share).
 *
 *         Deploy-only: listing iwSPYx (the OP ShadowOFT) as a reserve pointing at this feed is a
 *         separate step with its own collateral-factor decisions.
 *
 * Usage (simulate by dropping --broadcast):
 *   source .env && ENV=dev forge script \
 *     scripts/DeployWspyxOracleSinkFeed.s.sol:DeployWspyxOracleSinkFeed \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeployWspyxOracleSinkFeed is Utils {
    /// @dev Dev OracleSink on Optimism (cash-mainnet-asset-listing deployments/dev/10)
    address constant ORACLE_SINK = 0x83Ba7f354B705C34935437526Cf318c77d9093Aa;
    /// @dev Mainnet wSPYx (canonical wrapper) — the OracleSink price key (the relay ships mainnet token addresses)
    address constant WSPYX_MAINNET = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    /// @dev Chainlink SPY/USD (24/5) aggregator on Optimism, 8 decimals
    address constant SPY_USD_FEED = 0x5F77134CfAA7DB2906649Ca21C50dA54daE9291d;

    uint8 constant FEED_DECIMALS = 8;
    /// @dev 24/5 feed: must survive the Friday-close -> Sunday-reopen gap (~65h) with buffer,
    ///      mirroring the cash PriceProviderV2 config in cash-mainnet-asset-listing
    uint256 constant SPY_USD_MAX_STALENESS = 78 hours;
    /// @dev Max age of the relay's source-chain read. Driven by the keeper's poke cadence (the
    ///      rate itself moves ~quarterly); matches the sink's own dev window of 7 days
    uint256 constant SINK_RATE_MAX_STALENESS = 7 days;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "dev"), "dev-only: the OracleSink address is the dev deployment");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        ChainlinkPriceFeed spyUsd = new ChainlinkPriceFeed(IAggregatorV3(SPY_USD_FEED), IAaveV4PriceFeed(address(0)), FEED_DECIMALS, SPY_USD_MAX_STALENESS, false, "SPY / USD");
        OracleSinkPriceFeed iwspyxUsd = new OracleSinkPriceFeed(IOracleSink(ORACLE_SINK), WSPYX_MAINNET, spyUsd, FEED_DECIMALS, SINK_RATE_MAX_STALENESS, false, "iwSPYx / USD");

        vm.stopBroadcast();

        _requireLivePrice(address(spyUsd), "SPY / USD");
        _requireLivePrice(address(iwspyxUsd), "iwSPYx / USD");

        console.log("SPY / USD feed:    ", address(spyUsd));
        console.log("iwSPYx / USD feed: ", address(iwspyxUsd));
    }

    function _requireLivePrice(address feed, string memory desc) internal view {
        int256 answer = IAaveV4PriceFeed(feed).latestAnswer();
        require(answer > 0, string.concat("dead feed: ", desc));
        // 8-decimal USD, printed as dollars.cents for a quick eyeball check
        uint256 cents = (uint256(answer) % 1e8) / 1e6;
        console.log(string.concat("  ", desc, ": $", vm.toString(uint256(answer) / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents)));
    }
}
