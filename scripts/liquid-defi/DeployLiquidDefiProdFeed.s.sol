// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { CLRatePriceCapAdapter } from "../../src/oracle/capo/vendor/CLRatePriceCapAdapter.sol";
import { IACLManager } from "../../src/oracle/capo/vendor/IACLManager.sol";
import { IPriceCapAdapter } from "../../src/oracle/capo/vendor/IPriceCapAdapter.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";

/// @notice liquidDeFi (Midas vault, OP) price feed configuration. Every value mirrors the live liquidRWA /
///         liquidRESERVE stacks deployed by scripts/aave-v4/DeployCapoPriceAdapters (read on-chain 2026-11-03),
///         except the snapshot and the growth cap, which are per asset.
library LiquidDefiProd {
    // ---------------------------------------------------------------- Midas (OP)
    /// @dev liquidDeFi customFeed: "liquidDeFi/USD", 8 dec, latestRoundData only (latestAnswer reverts).
    ///      Same runtime bytecode as the liquidRESERVE (0x58dD...1356) and liquidRWA (0xd5aa...8080) proxies
    ///      the live rate legs read (codehash 0x4d9be648...d83e).
    address internal constant MIDAS_CUSTOM_FEED = 0xF354e713E9DF3CfBEbAD1221D779F6C4ca198a57;
    address internal constant UNDERLYING = 0x4299b11815F25DB50fC56CD8a1C24cCCDD2AEECe; // liquidDeFi, 18 dec

    // ---------------------------------------------------------------- shared, already live (OP)
    /// @dev The Aave v4 Cash AccessManager, passed as the CAPO ACL manager like every live adapter: it implements
    ///      neither isRiskAdmin nor isPoolAdmin, so setCapParameters is unreachable and the cap is immutable.
    address internal constant ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
    /// @dev OneUSDFixedAdapter ("ONE USD", 8 dec): the base leg of Capped liquidRESERVE / USD and Capped liquidRWA / USD
    address internal constant ONE_USD = 0xa35e69267b208e7B175Fa0e34cEf0AA0Ff18d0F6;

    // ---------------------------------------------------------------- rate leg (= liquidRWA / liquidRESERVE rate legs)
    uint8 internal constant RATE_DECIMALS = 8;
    uint256 internal constant MIDAS_MAX_STALENESS = 7 days;
    string internal constant RATE_DESCRIPTION = "liquidDeFi / USD rate";

    // ---------------------------------------------------------------- CAPO (= Capped liquidRWA / USD)
    string internal constant CAPO_DESCRIPTION = "Capped liquidDeFi / USD";
    uint48 internal constant MINIMUM_SNAPSHOT_DELAY = 7 days;
    /// @dev 1200 bps (12%) of yearly NAV growth, raised from the LIST-5 rollout figure of 9% (liquidRWA runs 900).
    ///      Same headroom as sETHFI (1200), the highest growth cap on the instance.
    uint16 internal constant MAX_YEARLY_GROWTH_BPS = 1200;
    /// @dev The vault's inception NAV. The customFeed's first and only round (roundId 1, 2026-10-29 13:11 UTC)
    ///      prints exactly 1.00000000, so the NAV cannot have been above 1e8 at any earlier time.
    uint104 internal constant SNAPSHOT_RATIO = 100_000_000;
    /// @dev 2026-10-27 00:00 UTC, 2.5 days before that first round. The CAPO constructor requires the snapshot to
    ///      be at least MINIMUM_SNAPSHOT_DELAY old, and the first round only clears 7 days on 2026-11-05 13:11 UTC.
    ///      Back-dating the 1.00 snapshot keeps the 7-day delay identical to liquidRWA / liquidRESERVE and only
    ///      lifts the ceiling by ~2.5 days of 12%/yr (~0.08%). Deployable until 180 days after this
    ///      (MAXIMUM_SNAPSHOT_TERM, 2027-04-25).
    uint48 internal constant SNAPSHOT_TIMESTAMP = 1_793_059_200;

    // ---------------------------------------------------------------- CREATE3 (EtherFiDeployer)
    string internal constant RATE_SALT = "LiquidDefiUsdRateFeed";
    string internal constant CAPO_SALT = "LiquidDefiUsdFeed";
    address internal constant EXPECTED_RATE_FEED = 0x56CC4A6fBe4D0366fc106650aF8b86F87AA95De3;
    /// @dev The aave-v4 AaveV4EtherfiCashAssets.LIQUID_DEFI_ORACLE pin
    address internal constant EXPECTED_CAPO_FEED = 0x71CDe3FA526ac8CaF6659bCB236730F0c7e7dA4a;
}

/**
 * @title DeployLiquidDefiProdFeed
 * @notice Deploys the Aave v4 price source for the liquidDeFi Summer Lend listing on Optimism and merges it into
 *         deployments/mainnet/10/summer-lend-feeds.json. Deploy-only and admin-less; the reserve listing against it
 *         is the aave-v4 timelock script's job (scripts/etherfi/listings there, LIQUID_DEFI_ORACLE).
 *
 *         The stack is the liquidRWA / liquidRESERVE one, bottom to top:
 *           Midas customFeed "liquidDeFi/USD"     (latestRoundData only)
 *             -> LiquidDefiUsdRateFeed  ChainlinkPriceFeed "liquidDeFi / USD rate", 8 dec, 7-day bound, no stable snap
 *               -> LiquidDefiUsdFeed    CLRatePriceCapAdapter "Capped liquidDeFi / USD" = ONE USD x min(rate, ceiling),
 *                                       12%/yr growth from a 1.00 snapshot, 7-day minimum snapshot delay, immutable cap
 *
 *         Both contracts go through the permissioned EtherFiDeployer (CREATE3), so the addresses are deterministic
 *         and asserted against the pins. The live liquidRWA / liquidRESERVE adapters were plain `new` deployments;
 *         CREATE3 is what lets aave-v4 pin LIQUID_DEFI_ORACLE (and schedule the listing) before this runs.
 *
 *         run()      broadcast (or dry-run) the deployment; idempotent (existing feeds are reused)
 *         verify()   read-only: both feeds deployed, wired like liquidRWA, and pricing. Require green before the
 *                    Timelock Safe EXECUTES the listing (addReserve reads the price)
 *         rehearse() fork-only: deploys as the pranked registered deployer and prints every address
 *
 * Usage (simulate by dropping --broadcast; the broadcaster must be a registered EtherFiDeployer deployer):
 *   source .env && ENV=mainnet forge script scripts/liquid-defi/DeployLiquidDefiProdFeed.s.sol:DeployLiquidDefiProdFeed \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 *   forge script scripts/liquid-defi/DeployLiquidDefiProdFeed.s.sol:DeployLiquidDefiProdFeed --sig 'verify()' --rpc-url $OPTIMISM_RPC
 *   forge script scripts/liquid-defi/DeployLiquidDefiProdFeed.s.sol:DeployLiquidDefiProdFeed --sig 'rehearse()' --rpc-url $OPTIMISM_RPC
 */
contract DeployLiquidDefiProdFeed is Utils {
    using SafeCast for int256;

    string constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";
    /// @dev Registered EtherFiDeployer deployer ($PROD_DEPLOYER), pranked for fork rehearsals
    address constant REGISTERED_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    /// @dev The live liquidRWA stack the new one must match field for field
    address constant LIVE_LIQUID_RWA_CAPO = 0x6Bf29C9bec671EE7787352EBc42c2151a7BC2854;
    address constant LIVE_LIQUID_RWA_RATE = 0x20fEA16693bF1399d876fe11780Fd4fcdcf19fAe;
    address constant LIVE_LIQUID_RWA_MIDAS = 0xd5aaE6ac1a9ed4BE5DcC1fc172EDeFFd5B6d8080;

    EtherFiDeployer internal etherFiDeployer;

    function run() public {
        _requireProdOptimism();
        vm.startBroadcast();
        (address rate, address capo) = _deployAll(false);
        vm.stopBroadcast();

        _requireLivePrice(rate, LiquidDefiProd.RATE_DESCRIPTION);
        _requireLivePrice(capo, LiquidDefiProd.CAPO_DESCRIPTION);
        _record(capo);
    }

    function verify() public view {
        _requireProdOptimism();
        require(LiquidDefiProd.EXPECTED_RATE_FEED.code.length > 0, "rate feed not deployed");
        require(LiquidDefiProd.EXPECTED_CAPO_FEED.code.length > 0, "CAPO feed not deployed");
        _assertWiring(LiquidDefiProd.EXPECTED_RATE_FEED, LiquidDefiProd.EXPECTED_CAPO_FEED);
        _requireLivePrice(LiquidDefiProd.EXPECTED_RATE_FEED, LiquidDefiProd.RATE_DESCRIPTION);
        _requireLivePrice(LiquidDefiProd.EXPECTED_CAPO_FEED, LiquidDefiProd.CAPO_DESCRIPTION);
    }

    function rehearse() public {
        _requireProdOptimism();
        (address rate, address capo) = _deployAll(true);
        _requireLivePrice(rate, LiquidDefiProd.RATE_DESCRIPTION);
        _requireLivePrice(capo, LiquidDefiProd.CAPO_DESCRIPTION);
    }

    /// @dev Deploys (or reuses) both feeds at their CREATE3 addresses; `rehearsal` pranks the registered deployer
    ///      instead of broadcasting (fork-only). Every immutable binding is asserted.
    function _deployAll(bool rehearsal) internal returns (address rate, address capo) {
        etherFiDeployer = EtherFiDeployer(vm.parseJsonAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer"));
        require(address(etherFiDeployer).code.length != 0, "EtherFiDeployer not deployed on this chain");
        if (rehearsal) require(etherFiDeployer.isDeployer(REGISTERED_DEPLOYER), "rehearsal prank address is not a registered deployer");
        _assertSources();

        rate = _create3(
            rehearsal,
            LiquidDefiProd.RATE_SALT,
            abi.encodePacked(
                type(ChainlinkPriceFeed).creationCode,
                abi.encode(LiquidDefiProd.MIDAS_CUSTOM_FEED, address(0), LiquidDefiProd.RATE_DECIMALS, LiquidDefiProd.MIDAS_MAX_STALENESS, false, LiquidDefiProd.RATE_DESCRIPTION)
            )
        );
        capo = _create3(
            rehearsal,
            LiquidDefiProd.CAPO_SALT,
            abi.encodePacked(
                type(CLRatePriceCapAdapter).creationCode,
                abi.encode(
                    IPriceCapAdapter.CapAdapterParams({
                        aclManager: IACLManager(LiquidDefiProd.ACCESS_MANAGER),
                        baseAggregatorAddress: LiquidDefiProd.ONE_USD,
                        ratioProviderAddress: rate,
                        pairDescription: LiquidDefiProd.CAPO_DESCRIPTION,
                        minimumSnapshotDelay: LiquidDefiProd.MINIMUM_SNAPSHOT_DELAY,
                        priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
                            snapshotRatio: LiquidDefiProd.SNAPSHOT_RATIO,
                            snapshotTimestamp: LiquidDefiProd.SNAPSHOT_TIMESTAMP,
                            maxYearlyRatioGrowthPercent: LiquidDefiProd.MAX_YEARLY_GROWTH_BPS
                        })
                    })
                )
            )
        );

        require(rate == LiquidDefiProd.EXPECTED_RATE_FEED, "rate feed != LiquidDefiProd.EXPECTED_RATE_FEED");
        require(capo == LiquidDefiProd.EXPECTED_CAPO_FEED, "CAPO feed != LiquidDefiProd.EXPECTED_CAPO_FEED (the aave-v4 LIQUID_DEFI_ORACLE pin)");
        _assertWiring(rate, capo);
    }

    /// @dev The inputs are what the liquidRWA stack reads: a Midas customFeed of the same code, and the live ONE USD base.
    function _assertSources() internal view {
        require(LiquidDefiProd.MIDAS_CUSTOM_FEED.codehash == LIVE_LIQUID_RWA_MIDAS.codehash, "customFeed code differs from the liquidRWA Midas proxy");
        require(IAggregatorV3(LiquidDefiProd.MIDAS_CUSTOM_FEED).decimals() == LiquidDefiProd.RATE_DECIMALS, "customFeed is not 8 decimals");
        require(keccak256(bytes(IAggregatorV3(LiquidDefiProd.MIDAS_CUSTOM_FEED).description())) == keccak256("liquidDeFi/USD"), "customFeed is not liquidDeFi/USD");
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(LiquidDefiProd.MIDAS_CUSTOM_FEED).latestRoundData();
        require(answer > 0 && block.timestamp - updatedAt <= LiquidDefiProd.MIDAS_MAX_STALENESS, "customFeed is dead or stale");

        require(address(CLRatePriceCapAdapter(LIVE_LIQUID_RWA_CAPO).BASE_TO_USD_AGGREGATOR()) == LiquidDefiProd.ONE_USD, "liquidRWA base moved off ONE USD");
        require(IAaveV4PriceFeed(LiquidDefiProd.ONE_USD).latestAnswer() == 1e8, "ONE USD is not 1e8");
        require(keccak256(bytes(IAggregatorV3(LiquidDefiProd.ONE_USD).description())) == keccak256("ONE USD"), "base is not ONE USD");
    }

    /// @dev Every binding of the new stack equals the live liquidRWA one, except description, snapshot, source and growth cap.
    function _assertWiring(address rate, address capo) internal view {
        ChainlinkPriceFeed r = ChainlinkPriceFeed(rate);
        ChainlinkPriceFeed liveR = ChainlinkPriceFeed(LIVE_LIQUID_RWA_RATE);
        require(address(r.rateFeed()) == LiquidDefiProd.MIDAS_CUSTOM_FEED, "rate leg reads the wrong Midas feed");
        require(address(r.underlyingUsdFeed()) == address(liveR.underlyingUsdFeed()) && address(r.underlyingUsdFeed()) == address(0), "rate leg must not compose a USD leg");
        require(r.rateMaxStaleness() == liveR.rateMaxStaleness(), "rate leg staleness != liquidRWA");
        require(r.isStableToken() == liveR.isStableToken() && !r.isStableToken(), "rate leg must not snap to $1");
        require(r.decimals() == liveR.decimals(), "rate leg decimals != liquidRWA");
        require(keccak256(bytes(r.description())) == keccak256(bytes(LiquidDefiProd.RATE_DESCRIPTION)), "rate leg description");

        CLRatePriceCapAdapter c = CLRatePriceCapAdapter(capo);
        CLRatePriceCapAdapter liveC = CLRatePriceCapAdapter(LIVE_LIQUID_RWA_CAPO);
        require(c.RATIO_PROVIDER() == rate, "CAPO ratio provider is not the rate leg");
        require(address(c.ACL_MANAGER()) == address(liveC.ACL_MANAGER()), "CAPO ACL manager != liquidRWA");
        require(address(c.BASE_TO_USD_AGGREGATOR()) == address(liveC.BASE_TO_USD_AGGREGATOR()), "CAPO base != liquidRWA");
        require(c.DECIMALS() == liveC.DECIMALS() && c.decimals() == 8, "CAPO decimals != liquidRWA");
        require(c.RATIO_DECIMALS() == liveC.RATIO_DECIMALS(), "CAPO ratio decimals != liquidRWA");
        require(c.MINIMUM_SNAPSHOT_DELAY() == liveC.MINIMUM_SNAPSHOT_DELAY(), "CAPO snapshot delay != liquidRWA");
        require(c.getMaxYearlyGrowthRatePercent() == LiquidDefiProd.MAX_YEARLY_GROWTH_BPS, "CAPO growth cap != MAX_YEARLY_GROWTH_BPS");
        require(c.getSnapshotRatio() == LiquidDefiProd.SNAPSHOT_RATIO && c.getSnapshotTimestamp() == LiquidDefiProd.SNAPSHOT_TIMESTAMP, "CAPO snapshot");
        require(c.getMaxRatioGrowthPerSecondScaled() > 0, "CAPO growth floored to zero: the ceiling would never rise");
        require(!c.isCapped(), "CAPO is already capping the live NAV");
        require(keccak256(bytes(c.description())) == keccak256(bytes(LiquidDefiProd.CAPO_DESCRIPTION)), "CAPO description");
    }

    /// @dev Deploys via the EtherFiDeployer at the salt-derived address; existing code means an earlier run landed it.
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
        uint256 usd = answer.toUint256();
        uint256 cents = (usd % 1e8) / 1e6;
        console.log(string.concat("  ", label, ": $", vm.toString(usd / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents), " at ", vm.toString(feed)));
    }

    function _requireProdOptimism() internal view {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet (or unset)");
    }

    /// @dev Merges the CAPO into summer-lend-feeds.json's `.details` map, preserving the entries
    function _record(address capo) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory existing = vm.readFile(path);

        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("liquiddefi-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        details = vm.serializeString("liquiddefi-details", "liquidDeFi", vm.serializeAddress("feed-liquidDeFi", "oracle", capo));

        vm.writeJson(vm.serializeString("liquiddefi-root", "details", details), path);
        console.log("Feed address merged into:", path);
    }
}
