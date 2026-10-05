// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IOracleSink } from "../../src/interfaces/IOracleSink.sol";
import { OracleSinkPriceFeed } from "../../src/oracle/OracleSinkPriceFeed.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";
import { IOracleSinkAdminLike, ZchfProd as C } from "./ZchfProdConfig.sol";

/**
 * @title DeployZchfProdFeed
 * @notice Deploys the Aave v4 "ZCHF / USD" price feed for the ZCHF Summer Lend prod listing on
 *         Optimism and merges its address into deployments/mainnet/10/summer-lend-feeds.json.
 *         Deploy-only and admin-less; the reserve listing against it is the aave-v4 timelock
 *         script's job (scripts/etherfi/zchf there).
 *
 *         One OracleSinkPriceFeed over the prod OracleSink keyed by MAINNET ZCHF (the relay ships
 *         mainnet token addresses), USD-quoted (no underlying leg: the relayed value IS CHF / USD),
 *         8 decimals, 7-day relay bound (the OP practice), no stable snap. Same class as the retired relay-side PAXG
 *         feed: a direct, uncapped market price.
 *
 *         Deploys through the permissioned EtherFiDeployer (CREATE3, salt ZchfProd.FEED_SALT), so
 *         the address is deterministic and asserted equal to ZchfProd.EXPECTED_FEED — the value
 *         pinned in aave-v4 as AaveV4EtherfiCashAssets.ZCHF_ORACLE.
 *
 *         run()      broadcast (or dry-run) the deployment; tolerates a sink that has not received
 *                    a ZCHF price yet (the feed is immutable, deploying ahead of the relay is safe)
 *         verify()   read-only: the feed at EXPECTED_FEED prices. Require green before the
 *                    Timelock Safe EXECUTES the listing (addReserve reads the price)
 *         rehearse() fork-only: deploys as the pranked registered deployer, seeds the sink if the
 *                    relay has not delivered, and proves the feed prices end to end
 *
 * Usage (simulate by dropping --broadcast; the broadcaster must be a registered EtherFiDeployer
 * deployer, e.g. $PROD_DEPLOYER):
 *   source .env && ENV=mainnet forge script scripts/zchf/DeployZchfProdFeed.s.sol:DeployZchfProdFeed \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 *   forge script scripts/zchf/DeployZchfProdFeed.s.sol:DeployZchfProdFeed --sig 'verify()' --rpc-url $OPTIMISM_RPC
 *   forge script scripts/zchf/DeployZchfProdFeed.s.sol:DeployZchfProdFeed --sig 'rehearse()' --rpc-url $OPTIMISM_RPC
 */
/// @dev The deploy / verify mechanics of the "ZCHF / USD" feed, shared with the bundle generators that
///      rehearsal-deploy it on a fork (scripts/zchf-usdt0-paxgy).
abstract contract ZchfFeedDeployer is Utils {
    string constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";
    /// @dev Registered EtherFiDeployer deployer ($PROD_DEPLOYER), pranked for fork rehearsals
    address constant REGISTERED_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    EtherFiDeployer internal etherFiDeployer;

    /// @dev Deploys (or reuses) the feed at its CREATE3 address; `rehearsal` pranks the registered
    ///      deployer instead of broadcasting (fork-only). Every immutable binding is asserted.
    function _deployFeed(bool rehearsal) internal returns (address feed) {
        etherFiDeployer = EtherFiDeployer(vm.parseJsonAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer"));
        require(address(etherFiDeployer).code.length != 0, "EtherFiDeployer not deployed on this chain");
        if (rehearsal) require(etherFiDeployer.isDeployer(REGISTERED_DEPLOYER), "rehearsal prank address is not a registered deployer");
        require(IOracleSink(C.ORACLE_SINK).decimals() == 6, "OracleSink is not 6 decimals");

        bytes32 salt = keccak256(bytes(C.FEED_SALT));
        feed = CREATE3.predictDeterministicAddress(salt, address(etherFiDeployer));
        require(feed == C.EXPECTED_FEED, "CREATE3 prediction != ZchfProd.EXPECTED_FEED (the aave-v4 ZCHF_ORACLE pin)");

        if (feed.code.length > 0) {
            console.log("  [SKIP] ZchfUsdFeed already deployed at", feed);
        } else {
            bytes memory initCode = abi.encodePacked(type(OracleSinkPriceFeed).creationCode, abi.encode(C.ORACLE_SINK, C.ZCHF_MAINNET, address(0), C.FEED_DECIMALS, C.ZCHF_RATE_MAX_STALENESS, C.ZCHF_IS_STABLE_TOKEN, C.FEED_DESCRIPTION));
            if (rehearsal) vm.prank(REGISTERED_DEPLOYER);
            address actual = etherFiDeployer.deploy(salt, initCode);
            require(actual == feed, "CREATE3 address mismatch");
            console.log(string.concat(rehearsal ? "  [REHEARSAL] " : "  ", "ZchfUsdFeed:"), feed);
        }

        OracleSinkPriceFeed f = OracleSinkPriceFeed(feed);
        require(address(f.sink()) == C.ORACLE_SINK, "feed reads the wrong sink");
        require(f.token() == C.ZCHF_MAINNET, "feed keyed by the wrong token");
        require(address(f.underlyingUsdFeed()) == address(0), "feed must be USD-quoted (no underlying leg)");
        require(f.rateMaxStaleness() == C.ZCHF_RATE_MAX_STALENESS, "feed relay bound");
        require(f.decimals() == C.FEED_DECIMALS, "feed decimals");
        require(!f.isStableToken(), "feed must not snap to 1 USD");
        require(keccak256(bytes(f.description())) == keccak256(bytes(C.FEED_DESCRIPTION)), "feed description");
    }

    function _requireLivePrice(address feed) internal view {
        int256 answer = IAaveV4PriceFeed(feed).latestAnswer();
        require(answer > 0, "dead feed: ZCHF / USD");
        _logUsd(feed, SafeCast.toUint256(answer));
    }

    /// @dev Fork-only: writes a fresh PricePoint into the sink's ERC-7201 storage, standing in for
    ///      the LayerZero-delivered relay message (layout self-checked against the live wSPYx entry).
    function _seedSinkPrice(address token, uint256 price6dp) internal {
        bytes32 base = 0x3e8ab8ffffa6cdbcb3cadbd9bce96c661061ed9516d20cf2ac88617c984e9200;
        require(uint256(vm.load(C.ORACLE_SINK, keccak256(abi.encode(0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, base)))) > 0, "OracleSink storage root does not match the live layout");
        bytes32 priceSlot = keccak256(abi.encode(token, base));
        vm.store(C.ORACLE_SINK, priceSlot, bytes32(price6dp));
        uint256 ts = block.timestamp;
        vm.store(C.ORACLE_SINK, bytes32(uint256(priceSlot) + 1), bytes32(ts | (ts << 64)));
        (, int256 answer,,,) = IOracleSinkAdminLike(C.ORACLE_SINK).latestRoundData(token);
        require(SafeCast.toUint256(answer) == price6dp, "sink seed did not read back");
        console.log("  [SEEDED] sink ZCHF price for the rehearsal:", price6dp);
    }

    function _logUsd(address feed, uint256 usd) internal pure {
        uint256 cents = (usd % 1e8) / 1e6;
        console.log(string.concat("  ZCHF / USD: $", vm.toString(usd / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents), " at ", vm.toString(feed)));
    }
}

contract DeployZchfProdFeed is ZchfFeedDeployer {
    function run() public {
        _requireProdOptimism();
        vm.startBroadcast();
        address feed = _deployFeed(false);
        vm.stopBroadcast();

        _reportPriceAllowingUnrelayed(feed);
        _record(feed);
    }

    function verify() public view {
        _requireProdOptimism();
        require(C.EXPECTED_FEED.code.length > 0, "feed not deployed");
        _requireLivePrice(C.EXPECTED_FEED);
    }

    function rehearse() public {
        _requireProdOptimism();
        address feed = _deployFeed(true);
        IOracleSinkAdminLike sink = IOracleSinkAdminLike(C.ORACLE_SINK);
        if (sink.maxStaleness(C.ZCHF_MAINNET) == 0) {
            vm.prank(C.OPERATING_SAFE);
            sink.setMaxStaleness(C.ZCHF_MAINNET, C.ORACLE_SINK_MAX_STALENESS);
        }
        (bool hasPrice,) = C.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (C.ZCHF_MAINNET)));
        if (!hasPrice) _seedSinkPrice(C.ZCHF_MAINNET, C.SEED_PRICE_6DP);
        _requireLivePrice(feed);
    }

    /// @dev Tolerates exactly one failure: the sink holds no ZCHF entry yet (relay not delivered).
    ///      A revert with a live sink price is a wiring bug in an immutable contract and reverts here.
    function _reportPriceAllowingUnrelayed(address feed) internal view {
        try IAaveV4PriceFeed(feed).latestAnswer() returns (int256 answer) {
            require(answer > 0, "dead feed: ZCHF / USD");
            _logUsd(feed, SafeCast.toUint256(answer));
        } catch {
            (bool sinkHasPrice,) = C.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (C.ZCHF_MAINNET)));
            require(!sinkHasPrice, "feed reverts despite a live sink price (wiring bug)");
            console.log("  [PENDING RELAY] ZCHF / USD deployed at", feed);
            console.log("                  The sink holds no ZCHF entry yet. The address is final; after the first");
            console.log("                  PriceRelay.poke run verify() and require it green BEFORE the listing executes.");
        }
    }

    /// @dev Merges the feed into summer-lend-feeds.json's `.details` map, preserving the entries
    function _record(address feed) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory existing = vm.readFile(path);

        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("zchf-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        details = vm.serializeString("zchf-details", "ZCHF", vm.serializeAddress("feed-ZCHF", "oracle", feed));

        vm.writeJson(vm.serializeString("zchf-root", "details", details), path);
        console.log("Feed address merged into:", path);
    }

    function _requireProdOptimism() internal view {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet (or unset)");
    }
}
