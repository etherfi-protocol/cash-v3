// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { OracleSinkPriceFeed } from "../../src/oracle/OracleSinkPriceFeed.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";
import { IOracleSinkAdminLike, IShadowOFTFactoryLike, QqqxProd as C } from "./QqqxProdConfig.sol";

/**
 * @title QqqxFeedDeployer
 * @notice Shared feed-deployment core for the iwQQQx listing. Everything deploys through the
 *         permissioned EtherFiDeployer (CREATE3, salts `QqqxProdFeeds.<Name>`), so the addresses
 *         are deterministic, nobody can squat them ahead of us, and a partial run resumes
 *         idempotently.
 *
 *         Two callers:
 *         - DeployQqqxProdFeeds broadcasts the real deployments (below).
 *         - The 3CP generators (Tasks B3/B4) rehearse against a fork before the broadcast has
 *           happened: they prank the registered deployer through the SAME deployer contract,
 *           salts and initcode, so the fork ends up with byte-identical code at the exact
 *           addresses the real broadcast will produce.
 *
 *         Unlike wSPYx/PAXG, the Repo A rails this listing depends on (the iwQQQx ShadowOFT and a
 *         relayed wQQQx sink price) do not exist yet anywhere — not even on a clean mainnet fork —
 *         because cash-mainnet-asset-listing's bundles have not executed. `_rehearseQqqxRails()`
 *         stands in for them on a fork only; it is never called from the broadcast path.
 */
abstract contract QqqxFeedDeployer is Utils {
    string constant SALT_PREFIX = "QqqxProdFeeds.";
    string constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";
    /// @dev Registered EtherFiDeployer deployer ($PROD_DEPLOYER), pranked for fork rehearsals
    address constant REGISTERED_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    EtherFiDeployer internal etherFiDeployer;

    function _loadEtherFiDeployer() internal {
        etherFiDeployer = EtherFiDeployer(vm.parseJsonAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer"));
        require(address(etherFiDeployer).code.length != 0, "EtherFiDeployer not deployed on this chain");
    }

    /// @dev Deploys (or reuses) the two feeds. `rehearsal = true` pranks the registered deployer
    ///      instead of broadcasting — fork-only, for the 3CP generators. The iwQQQx feed binds the
    ///      QQQ/USD leg immutably at construction, so QQQ must be deployed first.
    function _deployFeeds(bool rehearsal) internal returns (address qqqUsd, address iwqqqxUsd) {
        if (address(etherFiDeployer) == address(0)) _loadEtherFiDeployer();
        if (rehearsal) require(etherFiDeployer.isDeployer(REGISTERED_DEPLOYER), "rehearsal prank address is not a registered deployer");

        qqqUsd = _create3(rehearsal, "QqqUsdFeed", abi.encodePacked(type(ChainlinkPriceFeed).creationCode, abi.encode(C.QQQ_USD_AGGREGATOR, address(0), C.FEED_DECIMALS, C.QQQ_USD_MAX_STALENESS, false, "QQQ / USD")));
        iwqqqxUsd = _create3(rehearsal, "IWQqqXUsdFeed", abi.encodePacked(type(OracleSinkPriceFeed).creationCode, abi.encode(C.ORACLE_SINK, C.WQQQX_MAINNET, qqqUsd, C.FEED_DECIMALS, C.IWQQQX_RATE_MAX_STALENESS, false, "iwQQQx / USD")));

        require(address(OracleSinkPriceFeed(iwqqqxUsd).underlyingUsdFeed()) == qqqUsd, "iwQQQx feed not composed on the QQQ/USD leg");
        require(OracleSinkPriceFeed(iwqqqxUsd).token() == C.WQQQX_MAINNET, "iwQQQx feed keyed by the wrong token");
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

    /// @dev Fork-only rehearsal of the two rails the cash-mainnet-asset-listing bundles ship: the
    ///      iwQQQx ShadowOFT and a relayed wQQQx rate on the sink. Uses the real factory at the real
    ///      salt, so the fork ends up with the exact address the prod bundle will produce.
    function _rehearseQqqxRails() internal {
        IShadowOFTFactoryLike factory = IShadowOFTFactoryLike(C.SHADOW_OFT_FACTORY);
        require(factory.getDeterministicAddress(C.WQQQX_SALT) == C.IWQQQX, "iwQQQx CREATE3 prediction does not match the live factory");

        if (C.IWQQQX.code.length == 0) {
            vm.prank(C.OPERATING_SAFE);
            address deployed = factory.deployShadowOFT(C.WQQQX_SALT, C.IWQQQX_NAME, C.IWQQQX_SYMBOL, 18, C.OPERATING_SAFE);
            require(deployed == C.IWQQQX, "rehearsal iwQQQx address mismatch");
        }

        IOracleSinkAdminLike sink = IOracleSinkAdminLike(C.ORACLE_SINK);
        if (sink.maxStaleness(C.WQQQX_MAINNET) == 0) {
            vm.prank(C.OPERATING_SAFE);
            sink.setMaxStaleness(C.WQQQX_MAINNET, 7 days);
        }

        (bool ok,) = C.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (C.WQQQX_MAINNET)));
        if (!ok) _seedSinkPrice(1_002_725); // live convertToAssets(1e18), normalised to 6 decimals
    }

    /// @dev Writes a fresh PricePoint into the sink's ERC-7201 storage, standing in for the
    ///      LayerZero-delivered relay message. Layout per cash-mainnet-asset-listing's OracleSink:
    ///      `latest` mapping at the storage root, PricePoint packed as
    ///      {uint256 price}{uint64 updatedAt | uint64 srcUpdatedAt}.
    function _seedSinkPrice(uint256 price6dp) internal {
        bytes32 base = 0x3e8ab8ffffa6cdbcb3cadbd9bce96c661061ed9516d20cf2ac88617c984e9200;
        // Self-check the layout against the live wSPYx entry before trusting it for wQQQx.
        require(uint256(vm.load(C.ORACLE_SINK, keccak256(abi.encode(0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, base)))) > 0, "OracleSink storage root does not match the live layout");
        bytes32 priceSlot = keccak256(abi.encode(C.WQQQX_MAINNET, base));
        vm.store(C.ORACLE_SINK, priceSlot, bytes32(price6dp));
        uint256 ts = block.timestamp;
        vm.store(C.ORACLE_SINK, bytes32(uint256(priceSlot) + 1), bytes32(ts | (ts << 64)));
        (, int256 answer,,,) = IOracleSinkAdminLike(C.ORACLE_SINK).latestRoundData(C.WQQQX_MAINNET);
        require(SafeCast.toUint256(answer) == price6dp, "sink seed did not read back");
    }
}

/**
 * @title DeployQqqxProdFeeds
 * @notice Deploys the Aave v4 price feeds for the iwQQQx Summer Lend prod listing on Optimism and
 *         merges their addresses into deployments/mainnet/10/summer-lend-feeds.json. Deploy-only
 *         and admin-less; the reserve listing against these feeds is the Lend Owner Safe bundle's
 *         job (ListQqqxSummerLend3CP, Task B3).
 *
 *           1. QQQ/USD: staleness-checked ChainlinkPriceFeed over the 24/5 Chainlink aggregator,
 *              3-day bound (clears the ~65h weekend gap).
 *           2. iwQQQx/USD: OracleSinkPriceFeed over the prod OracleSink keyed by MAINNET wQQQx
 *              (the relay ships mainnet token addresses); the relayed value is the wQQQx -> QQQx
 *              rate, composed on the QQQ/USD leg (1 QQQx tracks 1 QQQ share). 3-day rate bound.
 *
 *              DELIBERATELY UNCAPPED, unlike every other rate-composed reserve on the live
 *              instance (which sit behind CLRatePriceCapAdapters): on a Nasdaq-100 constituent
 *              split or a QQQ share split the wQQQx -> QQQx rate jumps by the split factor while
 *              QQQ/USD drops by the same factor — the composed price stays continuous, but a
 *              growth-capped rate leg would clamp the jump and under-price every iwQQQx position
 *              by the split ratio, with an immutable cap that cannot be re-snapshotted. A
 *              legitimate unbounded jump makes a growth cap the wrong tool here — the same
 *              reasoning applied to iwSPYx.
 *
 *         PREREQUISITE: the OracleSink has never held a wQQQx price. Until the
 *         cash-mainnet-asset-listing Ethereum bundle executes and the relay keeper pokes,
 *         `_requireLivePrice` on the iwQQQx feed reverts below — the correct, fail-closed
 *         behaviour. This script does not (and must not) seed the sink; seeding only happens in
 *         `_rehearseQqqxRails()`, which Tasks B3/B4 use for fork-only rehearsal.
 *
 * Usage (simulate by dropping --broadcast; the broadcaster must be a registered
 * EtherFiDeployer deployer, e.g. $PROD_DEPLOYER):
 *   source .env && ENV=mainnet forge script \
 *     scripts/qqqx/DeployQqqxProdFeeds.s.sol:DeployQqqxProdFeeds \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeployQqqxProdFeeds is QqqxFeedDeployer {
    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet");
        require(IAggregatorV3(C.QQQ_USD_AGGREGATOR).decimals() == 8, "QQQ/USD aggregator is not 8 decimals");

        vm.startBroadcast();
        (address qqqUsd, address iwqqqxUsd) = _deployFeeds(false);
        vm.stopBroadcast();

        _requireLivePrice(qqqUsd, "QQQ / USD");
        _requireLivePrice(iwqqqxUsd, "iwQQQx / USD");

        _record(qqqUsd, iwqqqxUsd);
    }

    /// @dev Merges the two feeds into summer-lend-feeds.json's `.details` map, preserving the
    ///      existing entries
    function _record(address qqqUsd, address iwqqqxUsd) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory existing = vm.readFile(path);

        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("qqqx-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        details = vm.serializeString("qqqx-details", "QQQ", vm.serializeAddress("feed-QQQ", "oracle", qqqUsd));
        details = vm.serializeString("qqqx-details", "iwQQQx", vm.serializeAddress("feed-iwQQQx", "oracle", iwqqqxUsd));

        vm.writeJson(vm.serializeString("qqqx-root", "details", details), path);
        console.log("Feed addresses merged into:", path);
    }
}
