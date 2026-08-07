// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IOracleSink } from "../../src/interfaces/IOracleSink.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { OracleSinkPriceFeed } from "../../src/oracle/OracleSinkPriceFeed.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";
import { WspyxPaxgProd as C } from "./WspyxPaxgProdConfig.sol";

/**
 * @title WspyxPaxgFeedDeployer
 * @notice Shared feed-deployment core for the iwSPYx/iPAXG listing. Everything deploys through
 *         the permissioned EtherFiDeployer (CREATE3, salts `WspyxPaxgProdFeeds.<Name>`), so the
 *         addresses are deterministic, nobody can squat them ahead of us, and a partial run
 *         resumes idempotently.
 *
 *         Two callers:
 *         - DeployWspyxPaxgProdFeeds broadcasts the real deployments (below).
 *         - The 3CP generators rehearse against a fork before the broadcast has happened: they
 *           prank the registered deployer through the SAME deployer contract, salts and initcode,
 *           so the fork ends up with byte-identical code at the exact addresses the real
 *           broadcast will produce.
 */
abstract contract WspyxPaxgFeedDeployer is Utils {
    string constant SALT_PREFIX = "WspyxPaxgProdFeeds.";
    string constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";
    /// @dev Registered EtherFiDeployer deployer ($PROD_DEPLOYER), pranked for fork rehearsals
    address constant REGISTERED_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    EtherFiDeployer internal etherFiDeployer;

    function _loadEtherFiDeployer() internal {
        etherFiDeployer = EtherFiDeployer(vm.parseJsonAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer"));
        require(address(etherFiDeployer).code.length != 0, "EtherFiDeployer not deployed on this chain");
    }

    /// @dev Deploys (or reuses) the three feeds. `rehearsal = true` pranks the registered deployer
    ///      instead of broadcasting — fork-only, for the 3CP generators.
    function _deployFeeds(bool rehearsal) internal returns (address spyUsd, address iwspyxUsd, address paxgUsd) {
        if (address(etherFiDeployer) == address(0)) _loadEtherFiDeployer();
        if (rehearsal) require(etherFiDeployer.isDeployer(REGISTERED_DEPLOYER), "rehearsal prank address is not a registered deployer");

        spyUsd = _create3(rehearsal, "SpyUsdFeed", abi.encodePacked(type(ChainlinkPriceFeed).creationCode, abi.encode(C.SPY_USD_AGGREGATOR, address(0), C.FEED_DECIMALS, C.SPY_USD_MAX_STALENESS, false, "SPY / USD")));
        iwspyxUsd = _create3(rehearsal, "IWSpyXUsdFeed", abi.encodePacked(type(OracleSinkPriceFeed).creationCode, abi.encode(C.ORACLE_SINK, C.WSPYX_MAINNET, spyUsd, C.FEED_DECIMALS, C.IWSPYX_RATE_MAX_STALENESS, false, "iwSPYx / USD")));
        paxgUsd = _create3(rehearsal, "PaxgUsdFeed", abi.encodePacked(type(ChainlinkPriceFeed).creationCode, abi.encode(C.PAXG_USD_AGGREGATOR, address(0), C.FEED_DECIMALS, C.PAXG_USD_MAX_STALENESS, false, "PAXG / USD")));

        // An earlier partial run could leave IWSpyXUsdFeed pointing at a different SPY leg only if
        // the salt scheme changed; the immutable binding is what makes this worth asserting.
        require(address(OracleSinkPriceFeed(iwspyxUsd).underlyingUsdFeed()) == spyUsd, "iwSPYx feed not composed on the SPY/USD leg");
        require(OracleSinkPriceFeed(iwspyxUsd).token() == C.WSPYX_MAINNET, "iwSPYx feed keyed by the wrong token");
    }

    /// @dev Deploys via the EtherFiDeployer at the salt-derived address; a populated address means
    ///      a prior (possibly partial) run already deployed it, so reuse it instead of reverting
    function _create3(bool rehearsal, string memory name, bytes memory initCode) internal returns (address deployed) {
        bytes32 salt = keccak256(bytes(string.concat(SALT_PREFIX, name)));
        deployed = CREATE3.predictDeterministicAddress(salt, address(etherFiDeployer));

        if (deployed.code.length > 0) {
            console.log("  [SKIP]", name, "already deployed at", deployed);
            return deployed;
        }

        if (rehearsal) vm.prank(REGISTERED_DEPLOYER);
        address actual = etherFiDeployer.deploy(salt, initCode);
        require(actual == deployed, string.concat("CREATE3 address mismatch: ", name));
        require(deployed.code.length > 0, string.concat("CREATE3 verification failed: ", name));
        console.log(string.concat(rehearsal ? "  [REHEARSAL] " : "  ", name, ":"), deployed);
    }

    function _requireLivePrice(address feed, string memory desc) internal view {
        int256 answer = IAaveV4PriceFeed(feed).latestAnswer();
        require(answer > 0, string.concat("dead feed: ", desc));
        uint256 usd = SafeCast.toUint256(answer);
        // 8-decimal USD, printed as dollars.cents for a quick eyeball check
        uint256 cents = (usd % 1e8) / 1e6;
        console.log(string.concat("  ", desc, ": $", vm.toString(usd / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents), " at ", vm.toString(feed)));
    }
}

/**
 * @title DeployWspyxPaxgProdFeeds
 * @notice Deploys the Aave v4 price feeds for the iwSPYx and iPAXG Summer Lend prod listings on
 *         Optimism and merges their addresses into deployments/mainnet/10/summer-lend-feeds.json.
 *         Deploy-only and admin-less; the reserve listings against these feeds are the Lend Owner
 *         Safe bundle's job (ListWspyxPaxgSummerLend3CP).
 *
 *           1. SPY/USD: staleness-checked ChainlinkPriceFeed over the 24/5 Chainlink aggregator,
 *              3-day bound (clears the ~65h weekend gap).
 *           2. iwSPYx/USD: OracleSinkPriceFeed over the prod OracleSink keyed by MAINNET wSPYx
 *              (the relay ships mainnet token addresses); the relayed value is the wSPYx -> SPYx
 *              rate, composed on the SPY/USD leg (1 SPYx tracks 1 SPY share). 3-day rate bound.
 *
 *              DELIBERATELY UNCAPPED, unlike every other rate-composed reserve on the live
 *              instance (which sit behind CLRatePriceCapAdapters): on a SPY stock split or bonus
 *              issue the wSPYx -> SPYx rate jumps by the split factor while SPY/USD drops by the
 *              same factor — the composed price stays continuous, but a growth-capped rate leg
 *              would clamp the jump and under-price every iwSPYx position by the split ratio,
 *              with an immutable cap that cannot be re-snapshotted. A legitimate unbounded jump
 *              makes a growth cap the wrong tool here (the same reasoning the CAPO script gives
 *              for assets with market exposure in the ratio slot).
 *           3. PAXG/USD: staleness-checked ChainlinkPriceFeed over the native OP aggregator,
 *              1-day bound (~24h heartbeat). Also the new PriceProviderV2 source for iPAXG
 *              (ConfigureWspyxPaxgCashOP3CP points the cash side at the same aggregator).
 *
 * Usage (simulate by dropping --broadcast; the broadcaster must be a registered
 * EtherFiDeployer deployer, e.g. $PROD_DEPLOYER):
 *   source .env && ENV=mainnet forge script \
 *     scripts/wspyx-paxg/DeployWspyxPaxgProdFeeds.s.sol:DeployWspyxPaxgProdFeeds \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeployWspyxPaxgProdFeeds is WspyxPaxgFeedDeployer {
    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet");
        require(IAggregatorV3(C.PAXG_USD_AGGREGATOR).decimals() == 8, "PAXG/USD aggregator is not 8 decimals");
        require(IAggregatorV3(C.SPY_USD_AGGREGATOR).decimals() == 8, "SPY/USD aggregator is not 8 decimals");

        vm.startBroadcast();
        (address spyUsd, address iwspyxUsd, address paxgUsd) = _deployFeeds(false);
        vm.stopBroadcast();

        _requireLivePrice(spyUsd, "SPY / USD");
        _requireLivePrice(iwspyxUsd, "iwSPYx / USD");
        _requireLivePrice(paxgUsd, "PAXG / USD");

        _record(spyUsd, iwspyxUsd, paxgUsd);
    }

    /// @dev Merges the three feeds into summer-lend-feeds.json's `.details` map, preserving the
    ///      existing entries (SPY is not a reserve, recorded for traceability of the iwSPYx leg)
    function _record(address spyUsd, address iwspyxUsd, address paxgUsd) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory existing = vm.readFile(path);

        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("wspyx-paxg-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        details = vm.serializeString("wspyx-paxg-details", "SPY", vm.serializeAddress("feed-SPY", "oracle", spyUsd));
        details = vm.serializeString("wspyx-paxg-details", "iwSPYx", vm.serializeAddress("feed-iwSPYx", "oracle", iwspyxUsd));
        details = vm.serializeString("wspyx-paxg-details", "PAXG", vm.serializeAddress("feed-PAXG", "oracle", paxgUsd));

        vm.writeJson(vm.serializeString("wspyx-paxg-root", "details", details), path);
        console.log("Feed addresses merged into:", path);
    }
}
