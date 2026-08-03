// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../src/interfaces/IAaveV4PriceFeed.sol";
import { IOracleSink } from "../src/interfaces/IOracleSink.sol";
import { OracleSinkPriceFeed } from "../src/oracle/OracleSinkPriceFeed.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployPaxgOracleSinkFeed
 * @notice Deploys the iPAXG/USD price feed for the Aave v4 TEST instance on Optimism:
 *           1. iPAXG/USD: an OracleSinkPriceFeed over the dev OracleSink, keyed by the MAINNET
 *              PAXG address (the relay ships mainnet token addresses), whose relayed value is
 *              already the full PAXG/USD price (6 decimals) — unlike iwSPYx, no local underlying
 *              leg is composed on top.
 *
 *         Deploy-only: listing iPAXG (the OP ShadowOFT) as a reserve pointing at this feed is a
 *         separate step with its own collateral-factor decisions.
 *
 * Usage (simulate by dropping --broadcast):
 *   source .env && ENV=dev forge script \
 *     scripts/DeployPaxgOracleSinkFeed.s.sol:DeployPaxgOracleSinkFeed \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeployPaxgOracleSinkFeed is Utils {
    /// @dev Dev OracleSink on Optimism (cash-mainnet-asset-listing deployments/dev/10)
    address constant ORACLE_SINK = 0x83Ba7f354B705C34935437526Cf318c77d9093Aa;
    /// @dev Mainnet PAXG — the OracleSink price key (the relay ships mainnet token addresses)
    address constant PAXG_MAINNET = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    uint8 constant FEED_DECIMALS = 8;
    /// @dev Max age of the relay's source-chain read. Driven by the keeper's poke cadence, matches
    ///      the sink's own PAXG window of 2 days (24h Chainlink heartbeat x margin; tighter than
    ///      wSPYx's 7d because the relayed value is a live price, not a slow-moving rate)
    uint256 constant SINK_RATE_MAX_STALENESS = 2 days;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "dev"), "dev-only: the OracleSink address is the dev deployment");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // No underlying leg: the relayed price is already the full PAXG/USD price
        OracleSinkPriceFeed ipaxgUsd = new OracleSinkPriceFeed(IOracleSink(ORACLE_SINK), PAXG_MAINNET, IAaveV4PriceFeed(address(0)), FEED_DECIMALS, SINK_RATE_MAX_STALENESS, false, "iPAXG / USD");

        vm.stopBroadcast();

        _requireLivePrice(address(ipaxgUsd), "iPAXG / USD");

        console.log("iPAXG / USD feed:", address(ipaxgUsd));
    }

    function _requireLivePrice(address feed, string memory desc) internal view {
        int256 answer = IAaveV4PriceFeed(feed).latestAnswer();
        require(answer > 0, string.concat("dead feed: ", desc));
        // 8-decimal USD, printed as dollars.cents for a quick eyeball check
        uint256 cents = (uint256(answer) % 1e8) / 1e6;
        console.log(string.concat("  ", desc, ": $", vm.toString(uint256(answer) / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents)));
    }
}
