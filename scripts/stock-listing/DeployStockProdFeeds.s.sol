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
import { StockLendAssets } from "./StockLendAssets.sol";
import { IOracleSinkAdminLike, IShadowOFTFactoryLike, LendRails, StockLendAsset } from "./StockLendConfig.sol";

/**
 * @title StockFeedDeployer
 * @notice Shared feed-deployment core for a 4626-wrapped xStock's Summer Lend collateral listing.
 *         Everything deploys through the permissioned EtherFiDeployer (CREATE3, salts
 *         `<asset.feedSaltPrefix><name>`), so the addresses are deterministic, nobody can squat
 *         them ahead of us, and a partial run resumes idempotently.
 *
 *         Two callers:
 *         - The concrete Deploy*ProdFeeds contract broadcasts the real deployments (below).
 *         - The 3CP generators (List*SummerLend3CP / Configure*CashOP3CP) rehearse against a fork
 *           before the broadcast has happened: they prank the registered deployer through the
 *           SAME deployer contract, salts and initcode, so the fork ends up with byte-identical
 *           code at the exact addresses the real broadcast will produce.
 *
 *         For a brand-new asset, the cash-mainnet-asset-listing rails it depends on (the iToken
 *         ShadowOFT and a relayed wrapper sink price) will not exist yet anywhere — not even on a
 *         clean mainnet fork — until that repo's bundles execute. `_rehearseStockRails()` stands
 *         in for them on a fork only; it is never called from the broadcast path.
 */
abstract contract StockFeedDeployer is Utils {
    string constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";
    /// @dev Registered EtherFiDeployer deployer ($PROD_DEPLOYER), pranked for fork rehearsals
    address constant REGISTERED_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    EtherFiDeployer internal etherFiDeployer;

    function _loadEtherFiDeployer() internal {
        etherFiDeployer = EtherFiDeployer(vm.parseJsonAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer"));
        require(address(etherFiDeployer).code.length != 0, "EtherFiDeployer not deployed on this chain");
    }

    /// @dev Deploys (or reuses) the two feeds for `asset`. `rehearsal = true` pranks the
    ///      registered deployer instead of broadcasting — fork-only, for the 3CP generators. The
    ///      wrapper feed binds the stock/USD leg immutably at construction, so the stock feed
    ///      must be deployed first.
    function _deployFeeds(bool rehearsal, StockLendAsset memory asset) internal returns (address stockUsd, address wrapperUsd) {
        if (address(etherFiDeployer) == address(0)) _loadEtherFiDeployer();
        if (rehearsal) require(etherFiDeployer.isDeployer(REGISTERED_DEPLOYER), "rehearsal prank address is not a registered deployer");

        stockUsd = _create3(rehearsal, asset.feedSaltPrefix, asset.stockFeedName, abi.encodePacked(type(ChainlinkPriceFeed).creationCode, abi.encode(asset.usdAggregator, address(0), LendRails.FEED_DECIMALS, asset.usdFeedMaxStaleness, false, asset.stockFeedDesc)));
        wrapperUsd = _create3(rehearsal, asset.feedSaltPrefix, asset.wrapperFeedName, abi.encodePacked(type(OracleSinkPriceFeed).creationCode, abi.encode(LendRails.ORACLE_SINK, asset.wrapper, stockUsd, LendRails.FEED_DECIMALS, asset.rateMaxStaleness, false, asset.wrapperFeedDesc)));

        require(address(OracleSinkPriceFeed(wrapperUsd).underlyingUsdFeed()) == stockUsd, "wrapper feed not composed on the stock/USD leg");
        require(OracleSinkPriceFeed(wrapperUsd).token() == asset.wrapper, "wrapper feed keyed by the wrong token");

        // Refactor-time regression guard: a typo in any of the five ADDRESS-AFFECTING strings on
        // StockLendAsset silently deploys a different feed at a different address instead of
        // reusing the one already live. Zero disables the check for an asset with no prior
        // deployment to check against.
        if (asset.expectedStockFeed != address(0)) require(stockUsd == asset.expectedStockFeed, "stock feed address regression");
        if (asset.expectedWrapperFeed != address(0)) require(wrapperUsd == asset.expectedWrapperFeed, "wrapper feed address regression");
    }

    /// @dev Deploys via the EtherFiDeployer at the salt-derived address; a populated address means
    ///      a prior (possibly partial) run already deployed it, so reuse it instead of reverting
    /// @dev The CREATE3 address a feed salt resolves to. Sole definition of the salt scheme, so a
    ///      caller that only needs the address (the Verify* entrypoint) cannot drift from the one
    ///      that deploys.
    function _predictFeed(string memory saltPrefix, string memory name) internal view returns (address) {
        return CREATE3.predictDeterministicAddress(keccak256(bytes(string.concat(saltPrefix, name))), address(etherFiDeployer));
    }

    function _create3(bool rehearsal, string memory saltPrefix, string memory name, bytes memory initCode) internal returns (address deployed) {
        bytes32 salt = keccak256(bytes(string.concat(saltPrefix, name)));
        deployed = _predictFeed(saltPrefix, name);

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
        _logUsd(feed, desc, SafeCast.toUint256(answer));
    }

    /// @dev Same as {_requireLivePrice}, but tolerates the one failure that is expected when feeds
    ///      are deployed AHEAD of the listing bundles: the relay has not delivered a price for
    ///      `sinkToken` yet, so an OracleSink-backed leg cannot compose. The feeds are immutable and
    ///      admin-less, so deploying them early is safe and makes their addresses final before the
    ///      3CPs are proposed.
    ///
    ///      This is deliberately NOT a blanket try/catch. A revert is waved through ONLY when the
    ///      sink genuinely holds no entry for `sinkToken`. If the sink has a price and the feed
    ///      still reverts, that is a wiring bug in an immutable contract — it reverts here rather
    ///      than surfacing later as a failed `addReserve`. The structural bindings
    ///      (`underlyingUsdFeed()`, `token()`) are asserted unconditionally in {_deployFeeds}
    ///      regardless of this outcome.
    function _reportPriceAllowingUnrelayed(address feed, string memory desc, address sinkToken) internal view {
        try IAaveV4PriceFeed(feed).latestAnswer() returns (int256 answer) {
            require(answer > 0, string.concat("dead feed: ", desc));
            _logUsd(feed, desc, SafeCast.toUint256(answer));
        } catch {
            (bool sinkHasPrice,) = LendRails.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (sinkToken)));
            require(!sinkHasPrice, string.concat("feed reverts despite a live sink price (wiring bug): ", desc));
            console.log(string.concat("  [PENDING RELAY] ", desc, " deployed at ", vm.toString(feed)));
            console.log(string.concat("                  Cannot price yet: the OracleSink holds no entry for ", vm.toString(sinkToken), "."));
            console.log("                  The address is final. After the first PriceRelay.poke, run the Verify* entrypoint");
            console.log("                  and require it green BEFORE proposing the Summer Lend 3CP.");
        }
    }

    /// @dev 8-decimal USD, printed as dollars.cents for a quick eyeball check
    function _logUsd(address feed, string memory desc, uint256 usd) private pure {
        uint256 cents = (usd % 1e8) / 1e6;
        console.log(string.concat("  ", desc, ": $", vm.toString(usd / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents), " at ", vm.toString(feed)));
    }

    /// @dev Fork-only rehearsal of the two rails a cash-mainnet-asset-listing bundle ships: the
    ///      iToken ShadowOFT and a relayed wrapper rate on the sink. Uses the real factory at the
    ///      real salt, so the fork ends up with the exact address the prod bundle will produce.
    function _rehearseStockRails(StockLendAsset memory asset) internal {
        IShadowOFTFactoryLike factory = IShadowOFTFactoryLike(LendRails.SHADOW_OFT_FACTORY);
        bytes32 oftSalt = LendRails.oftSalt(asset.wrapper);
        require(factory.getDeterministicAddress(oftSalt) == asset.iToken, "iToken CREATE3 prediction does not match the live factory");

        if (asset.iToken.code.length == 0) {
            vm.prank(LendRails.OPERATING_SAFE);
            address deployed = factory.deployShadowOFT(oftSalt, asset.iTokenName, asset.iTokenSymbol, 18, LendRails.OPERATING_SAFE);
            require(deployed == asset.iToken, "rehearsal iToken address mismatch");
        }

        IOracleSinkAdminLike sink = IOracleSinkAdminLike(LendRails.ORACLE_SINK);
        if (sink.maxStaleness(asset.wrapper) == 0) {
            vm.prank(LendRails.OPERATING_SAFE);
            sink.setMaxStaleness(asset.wrapper, LendRails.ORACLE_SINK_MAX_STALENESS);
        }

        (bool ok,) = LendRails.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (asset.wrapper)));
        if (!ok) _seedSinkPrice(asset.wrapper, asset.seedRate6dp);
    }

    /// @dev Writes a fresh PricePoint into the sink's ERC-7201 storage, standing in for the
    ///      LayerZero-delivered relay message. Layout per cash-mainnet-asset-listing's OracleSink:
    ///      `latest` mapping at the storage root, PricePoint packed as
    ///      {uint256 price}{uint64 updatedAt | uint64 srcUpdatedAt}.
    function _seedSinkPrice(address token, uint256 price6dp) internal {
        bytes32 base = 0x3e8ab8ffffa6cdbcb3cadbd9bce96c661061ed9516d20cf2ac88617c984e9200;
        // Self-check the layout against the live wSPYx entry before trusting it for any other
        // asset. 0xE7E553…B540 is the PROD wSPYx wrapper (3CP 622 / cash-v3 WspyxPaxgProdConfig),
        // NOT the dev wrapper 0xc88FcD8B…4c02 that cash-mainnet-asset-listing's
        // ListWspyx*/PokeWspyx* scripts use — two 4626 wrappers share the SPYx underlying and only
        // the prod one has a live sink entry.
        require(uint256(vm.load(LendRails.ORACLE_SINK, keccak256(abi.encode(0xE7E553Cd128F0011777323A0b44a7b96EA1CB540, base)))) > 0, "OracleSink storage root does not match the live layout");
        bytes32 priceSlot = keccak256(abi.encode(token, base));
        vm.store(LendRails.ORACLE_SINK, priceSlot, bytes32(price6dp));
        uint256 ts = block.timestamp;
        vm.store(LendRails.ORACLE_SINK, bytes32(uint256(priceSlot) + 1), bytes32(ts | (ts << 64)));
        (, int256 answer,,,) = IOracleSinkAdminLike(LendRails.ORACLE_SINK).latestRoundData(token);
        require(SafeCast.toUint256(answer) == price6dp, "sink seed did not read back");
    }

    /// @dev Merges the two feeds into summer-lend-feeds.json's `.details` map, preserving the
    ///      existing entries
    function _record(StockLendAsset memory asset, address stockUsd, address wrapperUsd) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory existing = vm.readFile(path);

        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("stock-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        details = vm.serializeString("stock-details", asset.feedsJsonStockKey, vm.serializeAddress(string.concat("feed-", asset.feedsJsonStockKey), "oracle", stockUsd));
        details = vm.serializeString("stock-details", asset.feedsJsonWrapperKey, vm.serializeAddress(string.concat("feed-", asset.feedsJsonWrapperKey), "oracle", wrapperUsd));

        vm.writeJson(vm.serializeString("stock-root", "details", details), path);
        console.log("Feed addresses merged into:", path);
    }
}

/**
 * @title DeployStockProdFeedsBase
 * @notice Deploys the Aave v4 price feeds for a 4626-wrapped xStock's Summer Lend prod listing on
 *         Optimism and merges their addresses into deployments/mainnet/10/summer-lend-feeds.json.
 *         Deploy-only and admin-less; the reserve listing against these feeds is the Lend Owner
 *         Safe bundle's job (List*SummerLend3CP).
 *
 *           1. <STOCK>/USD: staleness-checked ChainlinkPriceFeed over the 24/5 Chainlink
 *              aggregator, `asset.usdFeedMaxStaleness` bound (clears the ~65h weekend gap).
 *           2. i<Token>/USD: OracleSinkPriceFeed over the prod OracleSink keyed by the MAINNET
 *              wrapper (the relay ships mainnet token addresses); the relayed value is the
 *              wrapper -> stock rate, composed on the <STOCK>/USD leg (1 stock share tracks 1
 *              wrapper share). `asset.rateMaxStaleness` bound.
 *
 *              DELIBERATELY UNCAPPED, unlike every other rate-composed reserve on the live
 *              instance (which sit behind CLRatePriceCapAdapters): on a constituent split or a
 *              share split the wrapper -> stock rate jumps by the split factor while <STOCK>/USD
 *              drops by the same factor — the composed price stays continuous, but a
 *              growth-capped rate leg would clamp the jump and under-price every position by the
 *              split ratio, with an immutable cap that cannot be re-snapshotted. A legitimate
 *              unbounded jump makes a growth cap the wrong tool here.
 *
 *         ORDERING: this can and should run BEFORE the listing 3CPs are proposed. The feeds are
 *         immutable and admin-less, so deploying them early is free and makes their addresses
 *         final — which the Summer Lend 3CP needs, since `addReserve` hardcodes the price source.
 *
 *         The wrapper leg cannot price until the cash-mainnet-asset-listing Ethereum bundle
 *         executes and the relay keeper pokes, so this script only WARNS on that specific
 *         condition (see `_reportPriceAllowingUnrelayed`) rather than reverting. It still reverts
 *         if the leg fails for any other reason. This script does not (and must not) seed the
 *         sink; seeding only happens in `_rehearseStockRails()`, which the 3CP generators use for
 *         fork-only rehearsal.
 *
 *         The liveness gate moved to `Verify*ProdFeeds` below. Run that after the first poke and
 *         require it green before proposing the Summer Lend 3CP.
 */
abstract contract DeployStockProdFeedsBase is StockFeedDeployer {
    function _asset() internal pure virtual returns (StockLendAsset memory);

    function run() public {
        StockLendAsset memory asset = _asset();

        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet");
        require(IAggregatorV3(asset.usdAggregator).decimals() == 8, "stock/USD aggregator is not 8 decimals");

        vm.startBroadcast();
        (address stockUsd, address wrapperUsd) = _deployFeeds(false, asset);
        vm.stopBroadcast();

        // The stock/USD leg reads a native Chainlink aggregator, so it must price the moment it is
        // deployed — a failure here is a real problem, never a sequencing artefact.
        _requireLivePrice(stockUsd, asset.stockFeedDesc);
        // The wrapper leg composes the relayed rate, which does not exist until the Ethereum
        // listing bundle executes and the keeper pokes. Deploying ahead of that is intended.
        _reportPriceAllowingUnrelayed(wrapperUsd, asset.wrapperFeedDesc, asset.wrapper);

        _record(asset, stockUsd, wrapperUsd);
    }
}

/**
 * @title VerifyStockProdFeedsBase
 * @notice The liveness gate that {DeployStockProdFeedsBase} deliberately does not enforce. Deploys
 *         nothing: it resolves both feeds at their CREATE3 addresses, asserts they are live, and
 *         requires BOTH legs to price.
 *
 *         Run this after the first `PriceRelay.poke` and require it green before proposing the
 *         Summer Lend 3CP — `addReserve` reads the wrapper feed, so a leg that cannot price here
 *         is a 3CP that will revert on execution.
 */
abstract contract VerifyStockProdFeedsBase is StockFeedDeployer {
    function _asset() internal pure virtual returns (StockLendAsset memory);

    function run() public {
        StockLendAsset memory asset = _asset();

        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet");

        _loadEtherFiDeployer();
        address stockUsd = _predictFeed(asset.feedSaltPrefix, asset.stockFeedName);
        address wrapperUsd = _predictFeed(asset.feedSaltPrefix, asset.wrapperFeedName);

        require(stockUsd.code.length > 0, "stock/USD feed not deployed; run the Deploy* entrypoint first");
        require(wrapperUsd.code.length > 0, "wrapper feed not deployed; run the Deploy* entrypoint first");
        // The composition is immutable, but re-read it here so this gate is a standalone statement
        // about the live contracts rather than a claim inherited from the deploy run.
        require(address(OracleSinkPriceFeed(wrapperUsd).underlyingUsdFeed()) == stockUsd, "wrapper feed not composed on the stock/USD leg");
        require(OracleSinkPriceFeed(wrapperUsd).token() == asset.wrapper, "wrapper feed keyed by the wrong token");

        _requireLivePrice(stockUsd, asset.stockFeedDesc);
        _requireLivePrice(wrapperUsd, asset.wrapperFeedDesc);

        console.log("  [OK] both legs live; safe to propose the Summer Lend 3CP");
    }
}

/**
 * @title VerifyQqqxProdFeeds
 * @notice iwQQQx's post-relay feed liveness gate. See VerifyStockProdFeedsBase.
 *
 * Usage:
 *   source .env && ENV=mainnet forge script \
 *     scripts/stock-listing/DeployStockProdFeeds.s.sol:VerifyQqqxProdFeeds --rpc-url $OPTIMISM_RPC -vvv
 */
contract VerifyQqqxProdFeeds is VerifyStockProdFeedsBase {
    function _asset() internal pure override returns (StockLendAsset memory) {
        return StockLendAssets.wqqqx();
    }
}

/**
 * @title DeployQqqxProdFeeds
 * @notice iwQQQx's Deploy*ProdFeeds. See DeployStockProdFeedsBase for the shared mechanics and
 *         StockLendAssets.wqqqx() for this asset's parameters and rollout-specific notes.
 *
 * Usage (simulate by dropping --broadcast; the broadcaster must be a registered
 * EtherFiDeployer deployer, e.g. $PROD_DEPLOYER):
 *   source .env && ENV=mainnet forge script \
 *     scripts/stock-listing/DeployStockProdFeeds.s.sol:DeployQqqxProdFeeds \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeployQqqxProdFeeds is DeployStockProdFeedsBase {
    function _asset() internal pure override returns (StockLendAsset memory) {
        return StockLendAssets.wqqqx();
    }
}
