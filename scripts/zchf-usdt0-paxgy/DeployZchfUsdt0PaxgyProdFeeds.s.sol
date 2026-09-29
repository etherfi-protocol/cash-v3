// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { ZchfFeedDeployer } from "../zchf/DeployZchfProdFeed.s.sol";
import { ZchfProd } from "../zchf/ZchfProdConfig.sol";
import { ZchfUsdt0PaxgyProd as C } from "./ZchfUsdt0PaxgyProdConfig.sol";

/// @dev The deploy mechanics of every rollout feed, shared with the bundle generator that
///      rehearsal-deploys them on a fork (ConfigureZchfUsdt0PaxgyCashOP3CP).
abstract contract RolloutFeedDeployer is ZchfFeedDeployer {
    string constant XAU_USD_SALT = "XauUsdFeed";
    string constant PAXGY_USD_SALT = "PaxgyUsdFeed";
    uint8 constant FEED_DECIMALS = 8;

    /// @dev Deploys (or reuses) every feed at its CREATE3 address; `rehearsal` pranks the registered
    ///      deployer instead of broadcasting (fork-only). Every immutable binding is asserted.
    function _deployAll(bool rehearsal) internal returns (address zchf, address xau, address paxgy) {
        zchf = _deployFeed(rehearsal); // ZchfFeedDeployer: sets etherFiDeployer, asserts ZchfProd.EXPECTED_FEED

        xau = _create3(rehearsal, XAU_USD_SALT, abi.encodePacked(type(ChainlinkPriceFeed).creationCode, abi.encode(C.XAU_USD_AGGREGATOR, address(0), FEED_DECIMALS, uint256(C.XAU_USD_MAX_STALENESS), false, "XAU / USD")));
        paxgy = _create3(rehearsal, PAXGY_USD_SALT, abi.encodePacked(type(ChainlinkPriceFeed).creationCode, abi.encode(C.PAXGY_XAU_RATE_FEED, xau, FEED_DECIMALS, uint256(C.PAXGY_XAU_MAX_STALENESS), false, "PAXGy / USD")));

        require(keccak256(bytes(IAggregatorV3(C.PAXGY_XAU_RATE_FEED).description())) == keccak256("PAXGy / Gold Exchange Rate"), "PAXGy rate feed is not the Chainlink PAXGy / Gold Exchange Rate");
        require(keccak256(bytes(IAggregatorV3(C.XAU_USD_AGGREGATOR).description())) == keccak256("XAU / USD"), "XAU aggregator is not Chainlink XAU / USD");
        require(address(ChainlinkPriceFeed(paxgy).underlyingUsdFeed()) == xau, "PAXGy feed not composed on the XAU / USD leg");
        require(address(ChainlinkPriceFeed(paxgy).rateFeed()) == C.PAXGY_XAU_RATE_FEED, "PAXGy feed reads the wrong rate");
        require(ChainlinkPriceFeed(paxgy).rateMaxStaleness() == C.PAXGY_XAU_MAX_STALENESS, "PAXGy rate bound");
        require(ChainlinkPriceFeed(xau).rateMaxStaleness() == C.XAU_USD_MAX_STALENESS, "XAU bound");
        require(ChainlinkPriceFeed(paxgy).decimals() == FEED_DECIMALS && ChainlinkPriceFeed(xau).decimals() == FEED_DECIMALS, "feed decimals");
        require(xau == C.LEND_XAU_FEED, "XAU feed != ZchfUsdt0PaxgyProd.LEND_XAU_FEED");
        require(paxgy == C.LEND_PAXGY_FEED, "PAXGy feed != ZchfUsdt0PaxgyProd.LEND_PAXGY_FEED (the aave-v4 PAXGY_ORACLE pin)");
    }

    /// @dev Deploys via the EtherFiDeployer at the salt-derived address; existing code means an
    ///      earlier run landed it (immutable, so nothing to re-check but the address).
    function _create3(bool rehearsal, string memory saltLabel, bytes memory initCode) internal returns (address feed) {
        bytes32 salt = keccak256(bytes(saltLabel));
        feed = CREATE3.predictDeterministicAddress(salt, address(etherFiDeployer));
        if (feed.code.length > 0) {
            console.log(string.concat("  [SKIP] ", saltLabel, " already deployed at"), feed);
            return feed;
        }
        if (rehearsal) vm.prank(REGISTERED_DEPLOYER);
        address actual = etherFiDeployer.deploy(salt, initCode);
        require(actual == feed, "CREATE3 address mismatch");
        console.log(string.concat(rehearsal ? "  [REHEARSAL] " : "  ", saltLabel, ":"), feed);
    }

    function _requireLivePrice(address feed, string memory label) internal view {
        int256 answer = IAaveV4PriceFeed(feed).latestAnswer();
        require(answer > 0, string.concat("dead feed: ", label));
        uint256 usd = SafeCast.toUint256(answer);
        uint256 cents = (usd % 1e8) / 1e6;
        console.log(string.concat("  ", label, ": $", vm.toString(usd / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents), " at ", vm.toString(feed)));
    }

    function _requireProdOptimism() internal view {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet (or unset)");
    }
}

/**
 * @title DeployZchfUsdt0PaxgyProdFeeds
 * @notice Deploys every Aave v4 price feed the ZCHF + USDT0 + PAXGy Summer Lend listings need on
 *         Optimism and merges the addresses into deployments/mainnet/10/summer-lend-feeds.json.
 *         Deploy-only and admin-less; the reserve listings against them are the aave-v4 timelock
 *         script's job (scripts/etherfi/listings there).
 *
 *           ZchfUsdFeed   OracleSinkPriceFeed  "ZCHF / USD"   sink(mainnet ZCHF), 8 dec, 7-day relay bound
 *                         (scripts/zchf/DeployZchfProdFeed's feed — same salt, same address). 7 days = the bound of every
 *                         live cash-v3 Summer Lend feed on OP (verified 2026-09-23); salts are the bare feed names.
 *           XauUsdFeed    ChainlinkPriceFeed   "XAU / USD"    Chainlink XAU / USD, 8 dec, 7-day bound
 *           PaxgyUsdFeed  ChainlinkPriceFeed   "PAXGy / USD"  Chainlink PAXGy / Gold Exchange Rate (18 dec)
 *                         x XauUsdFeed, 8 dec, 7-day rate bound — a rate-composed price, deliberately
 *                         uncapped: the PAXGy -> XAU rate is yield accrual, XAU / USD a market price
 *           USDT0 needs no feed: its reserve reads the live "Capped USDT / USD" CAPO adapter.
 *
 *         Deploys through the permissioned EtherFiDeployer (CREATE3), so every address is
 *         deterministic and asserted against the pins (ZchfProd.EXPECTED_FEED, LEND_XAU_FEED,
 *         LEND_PAXGY_FEED — the latter two pinned in aave-v4 AaveV4EtherfiCashAssets.PAXGY_ORACLE's leg).
 *
 *         run()      broadcast (or dry-run) the deployments; idempotent (existing feeds are reused)
 *         verify()   read-only: every feed prices. Require green before the Timelock Safe EXECUTES
 *                    the listings (addReserve reads the price)
 *         rehearse() fork-only: deploys as the pranked registered deployer and prints every address
 *
 * Usage (simulate by dropping --broadcast; the broadcaster must be a registered EtherFiDeployer deployer):
 *   source .env && ENV=mainnet forge script scripts/zchf-usdt0-paxgy/DeployZchfUsdt0PaxgyProdFeeds.s.sol:DeployZchfUsdt0PaxgyProdFeeds \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 *   forge script scripts/zchf-usdt0-paxgy/DeployZchfUsdt0PaxgyProdFeeds.s.sol:DeployZchfUsdt0PaxgyProdFeeds --sig 'verify()' --rpc-url $OPTIMISM_RPC
 *   forge script scripts/zchf-usdt0-paxgy/DeployZchfUsdt0PaxgyProdFeeds.s.sol:DeployZchfUsdt0PaxgyProdFeeds --sig 'rehearse()' --rpc-url $OPTIMISM_RPC
 */
contract DeployZchfUsdt0PaxgyProdFeeds is RolloutFeedDeployer {
    function run() public {
        _requireProdOptimism();
        vm.startBroadcast();
        (address zchf, address xau, address paxgy) = _deployAll(false);
        vm.stopBroadcast();

        _requireLivePrice(zchf, "ZCHF / USD");
        _requireLivePrice(xau, "XAU / USD");
        _requireLivePrice(paxgy, "PAXGy / USD");
        _record(zchf, xau, paxgy);
    }

    function verify() public view {
        _requireProdOptimism();
        require(ZchfProd.EXPECTED_FEED.code.length > 0, "ZCHF feed not deployed");
        require(C.LEND_XAU_FEED.code.length > 0, "XAU feed not deployed");
        require(C.LEND_PAXGY_FEED.code.length > 0, "PAXGy feed not deployed");
        _requireLivePrice(ZchfProd.EXPECTED_FEED, "ZCHF / USD");
        _requireLivePrice(C.LEND_XAU_FEED, "XAU / USD");
        _requireLivePrice(C.LEND_PAXGY_FEED, "PAXGy / USD");
    }

    function rehearse() public {
        _requireProdOptimism();
        (address zchf, address xau, address paxgy) = _deployAll(true);
        _requireLivePrice(zchf, "ZCHF / USD");
        _requireLivePrice(xau, "XAU / USD");
        _requireLivePrice(paxgy, "PAXGy / USD");
    }

    /// @dev Merges the feeds into summer-lend-feeds.json's `.details` map, preserving the entries
    function _record(address zchf, address xau, address paxgy) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory existing = vm.readFile(path);

        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("rollout-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        details = vm.serializeString("rollout-details", "ZCHF", vm.serializeAddress("feed-ZCHF", "oracle", zchf));
        details = vm.serializeString("rollout-details", "XAU", vm.serializeAddress("feed-XAU", "oracle", xau));
        details = vm.serializeString("rollout-details", "PAXGy", vm.serializeAddress("feed-PAXGy", "oracle", paxgy));

        vm.writeJson(vm.serializeString("rollout-root", "details", details), path);
        console.log("Feed addresses merged into:", path);
    }
}
