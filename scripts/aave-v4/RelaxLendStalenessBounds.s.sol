// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { CLRatePriceCapAdapter } from "../../src/oracle/capo/vendor/CLRatePriceCapAdapter.sol";
import { EURPriceCapAdapterStable } from "../../src/oracle/capo/vendor/EURPriceCapAdapterStable.sol";
import { IACLManager } from "../../src/oracle/capo/vendor/IACLManager.sol";
import { IChainlinkAggregator } from "../../src/oracle/capo/vendor/IChainlinkAggregator.sol";
import { ICLSynchronicityPriceAdapter } from "../../src/oracle/capo/vendor/ICLSynchronicityPriceAdapter.sol";
import { IEURPriceCapAdapterStable } from "../../src/oracle/capo/vendor/IEURPriceCapAdapterStable.sol";
import { IPriceCapAdapter } from "../../src/oracle/capo/vendor/IPriceCapAdapter.sol";

interface ISpokeLike {
    function getReserveCount() external view returns (uint256);
}

interface IAaveOracleLike {
    function getReserveSource(uint256 reserveId) external view returns (address);
    function getReservePrice(uint256 reserveId) external view returns (uint256);
}

interface ISpokeConfiguratorLike {
    function updateReservePriceSource(address spoke, uint256 reserveId, address priceSource) external;
}

/**
 * @title RelaxLendStalenessBounds
 * @notice 3CP-644. Raises the staleness bound on four USD legs of the ether.fi Cash Aave v4 instance
 *         on OP Mainnet, and rebuilds the four cap adapters that bake those legs in immutably.
 *
 *           ETHFI / USD   6h -> 36h     (reserve 8 direct, reserve 9 sETHFI via its adapter)
 *           HYPE  / USD   6h -> 36h     (reserve 11 direct, reserve 12 beHYPE via its adapter)
 *           OP    / USD   24h -> 36h    (reserve 10 direct)
 *           EUR   / USD   2d -> 7d      (reserve 3 EURC and reserve 17 weEUR, both via adapters)
 *
 *         WHY A REDEPLOY AND NOT A SETTER. Two separate immutables force it. Our `ChainlinkPriceFeed`
 *         holds `rateMaxStaleness` immutable, and Aave's cap adapters hold `BASE_TO_USD_AGGREGATOR`
 *         immutable — and the cap setters on those adapters are permanently unreachable on this
 *         instance by design (the ACL manager is the AccessManager, which implements neither
 *         `isRiskAdmin` nor `isPoolAdmin`; see DeployCapoPriceAdapters._aclManager). So changing a
 *         bound means a new leg, and a new leg means every adapter sitting on it is rebuilt too.
 *
 *         NOTHING ELSE CHANGES. Each new leg wraps the SAME Chainlink aggregator as the leg it
 *         replaces, and each rebuilt adapter reuses the SAME ratio provider and carries the SAME
 *         growth-cap snapshot forward, read off the live adapter rather than restated as a constant.
 *         The cap does not loosen and no risk parameter is re-tuned. `_verify` asserts every new
 *         source prices EXACTLY equal to the live one — not within a tolerance — because with the
 *         same aggregator, same ratio provider and same snapshot there is no legitimate reason for
 *         a single wei of drift.
 *
 *         WHAT THIS DOES CHANGE, STATED PLAINLY: it is a risk loosening. The 6h bound on ETHFI and
 *         HYPE was a deliberate choice for two fast deviation-driven feeds (~40 and ~34 updates/day).
 *         At 36h a 35-hour-old ETHFI price is accepted as fresh for both ETHFI and sETHFI collateral.
 *         EUR/USD at 7d becomes the loosest USD leg in the market, and it prices EURC, a stable.
 *
 *         This script never repoints a reserve. `updateReservePriceSource` sits on the configurator
 *         domain-admin role (400, Owner Safe only), so the swap is an Owner Safe batch — written to
 *         output/3CP-644-RelaxLendStaleness-10.json for the Safe Transaction Builder.
 *
 * Usage — dry run first (no --broadcast), which still runs every assertion:
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RelaxLendStalenessBounds.s.sol:RelaxLendStalenessBounds \
 *     --rpc-url $OPTIMISM_RPC --sender <deployer address> -vvv
 *
 * Then broadcast and verify:
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RelaxLendStalenessBounds.s.sol:RelaxLendStalenessBounds \
 *     --rpc-url $OPTIMISM_RPC --account etherfi-deployer --sender <deployer address> \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 */
contract RelaxLendStalenessBounds is Script {
    // ---------------------------------------------------------------- instance (OP Mainnet)
    address constant ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
    address constant SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    address constant OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

    // ---------------------------------------------------------------- Chainlink aggregators
    // Each new leg must wrap exactly these — the same aggregators the live legs wrap.
    address constant ETHFI_USD = 0x9A3C975993354354080d815e313eEEdEb907fF34; // 18 dec
    address constant HYPE_USD = 0x961f6a07bFc62F618a4fA737eDe08F23aD6Da67F; // 8 dec
    address constant OP_USD = 0x0D276FC14719f9292D5C1eA2198673d1f4269246; // 8 dec
    address constant EUR_USD = 0x3626369857A10CcC6cc3A6e4f5C2f5984a519F20; // 8 dec

    // ---------------------------------------------------------------- live sources being replaced
    // Read back from the oracle in _verify too; these constants exist so a source that has already
    // moved fails the run instead of being silently rebuilt from something unexpected.
    address constant LIVE_ETHFI_FEED = 0x89AB0BeEF8f88933f4724a2D0C4a149c644a8a80;
    address constant LIVE_HYPE_FEED = 0x7405E1C9a5AdC2A1730f38186f5845EC54Cd1B22;
    address constant LIVE_OP_FEED = 0x6D53a69EBC75cFeDf319F77569a4F732f75AED79;
    address constant LIVE_SETHFI_ADAPTER = 0xaF8749C3DC1Fc0592f21c2593204C45D3bE0d322;
    address constant LIVE_BEHYPE_ADAPTER = 0xefeDBa79436767AAfcF7902C66383d4735DacA50;
    address constant LIVE_WEEUR_ADAPTER = 0x7605dbe2948C99a559B9a065881916Ef043dA567;
    address constant LIVE_EURC_ADAPTER = 0xcBF18F68e2aBd480231241fa97BD41aE556433A0;

    // ---------------------------------------------------------------- staleness bounds
    uint256 constant OLD_FAST = 6 hours; // ETHFI, HYPE
    uint256 constant OLD_OP = 1 days;
    uint256 constant OLD_EUR = 2 days;

    uint256 constant NEW_FAST = 36 hours; // ETHFI, HYPE, OP
    uint256 constant NEW_EUR = 7 days;

    uint8 constant USD_FEED_DECIMALS = 8;

    /// @dev Aave's `PriceCapAdapterBase` rejects a snapshot older than this, so a carried-forward
    ///      snapshot has a deploy deadline. Checked before every rebuild.
    uint48 constant MAX_SNAPSHOT_TERM = 180 days;

    // ---------------------------------------------------------------- expected cap parameters
    // The cap values risk signed off on at the CAPO rollout, read back off the live adapters on
    // 2026-08-13 and pinned here. The rebuild reads the LIVE values and passes them through, but it
    // also asserts they still equal these — so a re-snapshot that happened between review and deploy
    // fails the run instead of being silently carried into the new adapters.
    uint104 constant SNAP_SETHFI = 1_187_971_295_403_462_986;
    uint48 constant SNAP_TS_SETHFI = 1_780_627_963;
    uint16 constant GROWTH_SETHFI = 1200; // 12.00%

    uint104 constant SNAP_WEEUR = 100_205_896; // 8 dec
    uint48 constant SNAP_TS_WEEUR = 1_780_627_963;
    uint16 constant GROWTH_WEEUR = 900; //  9.00%

    uint104 constant SNAP_BEHYPE = 1_018_457_451_127_239_140;
    uint48 constant SNAP_TS_BEHYPE = 1_785_344_431;
    uint16 constant GROWTH_BEHYPE = 300; //  3.00%

    int256 constant EURC_CAP_RATIO = 1.04e8;

    // ---------------------------------------------------------------- reserve ids
    uint256 constant RESERVE_EURC = 3;
    uint256 constant RESERVE_ETHFI = 8;
    uint256 constant RESERVE_SETHFI = 9;
    uint256 constant RESERVE_OP = 10;
    uint256 constant RESERVE_WHYPE = 11;
    uint256 constant RESERVE_BEHYPE = 12;
    uint256 constant RESERVE_WEEUR = 17;

    struct Result {
        string symbol;
        uint256 reserveId;
        address newSource;
        address replaces;
        uint256 price;
    }

    Result[] internal results;

    function run() public {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        require(ACCESS_MANAGER.code.length != 0, "no code at the AccessManager");

        vm.startBroadcast();

        // ---- new legs, each wrapping the same aggregator as the leg it replaces
        address ethfiUsd = _leg(LIVE_ETHFI_FEED, ETHFI_USD, OLD_FAST, NEW_FAST, "ETHFI / USD");
        address hypeUsd = _leg(LIVE_HYPE_FEED, HYPE_USD, OLD_FAST, NEW_FAST, "HYPE / USD");
        address opUsd = _leg(LIVE_OP_FEED, OP_USD, OLD_OP, NEW_FAST, "OP / USD");
        // The EUR leg is not a reserve source itself; it is only ever a cap-adapter base.
        address eurUsd = _legOnly(EUR_USD, NEW_EUR, "EUR / USD");

        // ---- reserves that read a leg directly
        _record("ETHFI", ethfiUsd, RESERVE_ETHFI);
        _record("wHYPE", hypeUsd, RESERVE_WHYPE);
        _record("OP", opUsd, RESERVE_OP);

        // ---- cap adapters rebuilt on the new legs, snapshots carried forward verbatim
        _record("sETHFI", _rebuildGrowth(LIVE_SETHFI_ADAPTER, ethfiUsd, "sETHFI", SNAP_SETHFI, SNAP_TS_SETHFI, GROWTH_SETHFI), RESERVE_SETHFI);
        _record("beHYPE", _rebuildGrowth(LIVE_BEHYPE_ADAPTER, hypeUsd, "beHYPE", SNAP_BEHYPE, SNAP_TS_BEHYPE, GROWTH_BEHYPE), RESERVE_BEHYPE);
        _record("weEUR", _rebuildGrowth(LIVE_WEEUR_ADAPTER, eurUsd, "weEUR", SNAP_WEEUR, SNAP_TS_WEEUR, GROWTH_WEEUR), RESERVE_WEEUR);
        _record("EURC", _rebuildEurStable(LIVE_EURC_ADAPTER, eurUsd), RESERVE_EURC);

        vm.stopBroadcast();

        _verify();
        _rehearse();
        _printSafeBatch();
        _writeSafeBatchJson();
        _writeJson();
    }

    // ------------------------------------------------------------------ legs

    /// @dev Deploys the replacement for a live `ChainlinkPriceFeed`, asserting first that the live one
    ///      is what we think it is: same aggregator, and the exact bound we are claiming to change.
    function _leg(address liveFeed, address aggregator, uint256 oldBound, uint256 newBound, string memory desc)
        internal
        returns (address)
    {
        ChainlinkPriceFeed live = ChainlinkPriceFeed(liveFeed);
        require(address(live.rateFeed()) == aggregator, string.concat(desc, ": live leg wraps a different aggregator"));
        require(live.rateMaxStaleness() == oldBound, string.concat(desc, ": live bound is not the one this run assumes"));
        require(!live.isStableToken(), string.concat(desc, ": live leg snaps to $1, the replacement would not match"));
        return _legOnly(aggregator, newBound, desc);
    }

    /// @dev The deploy itself. `isStableToken` is false everywhere here, matching the capo rollout:
    ///      the +/-1% snap to $1 is replaced by the cap adapters' upside-only cap.
    function _legOnly(address aggregator, uint256 newBound, string memory desc) internal returns (address) {
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(
            IAggregatorV3(aggregator), IAaveV4PriceFeed(address(0)), USD_FEED_DECIMALS, newBound, false, desc
        );
        require(feed.latestAnswer() > 0, string.concat("dead leg: ", desc));
        require(feed.rateMaxStaleness() == newBound, string.concat(desc, ": bound did not take"));
        require(feed.decimals() == USD_FEED_DECIMALS, string.concat(desc, ": leg decimals != 8"));
        console.log(string.concat("  leg ", desc, "  ", vm.toString(address(feed)), "  bound=", vm.toString(newBound), "s"));
        return address(feed);
    }

    // ------------------------------------------------------------------ adapter rebuilds

    /// @dev Rebuilds a `CLRatePriceCapAdapter` with a new base leg and everything else carried over
    ///      from the live adapter: ratio provider, description, minimum snapshot delay, and the full
    ///      cap snapshot. Nothing is restated as a constant, so nothing can drift from what is live.
    ///
    ///      `RATIO_DECIMALS` needs no handling — `CLRatePriceCapAdapter` derives it from the ratio
    ///      provider's `decimals()`, and the ratio provider is reused unchanged.
    function _rebuildGrowth(
        address liveAdapter,
        address newBase,
        string memory symbol,
        uint104 expectedRatio,
        uint48 expectedTs,
        uint16 expectedGrowth
    ) internal returns (address) {
        IPriceCapAdapter live = IPriceCapAdapter(liveAdapter);

        address ratioProvider = live.RATIO_PROVIDER();
        address liveBase = address(live.BASE_TO_USD_AGGREGATOR());
        require(liveBase != newBase, string.concat(symbol, ": live adapter already reads the new base"));
        _requireSameAggregator(symbol, liveBase, newBase);

        uint256 snapshotRatio = live.getSnapshotRatio();
        uint256 snapshotTs = live.getSnapshotTimestamp();
        uint256 growthPercent = live.getMaxYearlyGrowthRatePercent();
        uint48 minDelay = live.MINIMUM_SNAPSHOT_DELAY();

        // The live cap must still be the one risk signed off on. If it has been re-snapshotted since
        // this change was written, stop — carrying an unreviewed cap forward is not this script's call.
        require(snapshotRatio == expectedRatio, string.concat(symbol, ": live snapshot ratio is not the reviewed value"));
        require(snapshotTs == expectedTs, string.concat(symbol, ": live snapshot timestamp is not the reviewed value"));
        require(growthPercent == expectedGrowth, string.concat(symbol, ": live growth percent is not the reviewed value"));

        // Aave's `_setCapParameters` window. Failing here means the carried snapshot has aged out and
        // a fresh one must be taken and risk-reviewed — do NOT paper over it by loosening the growth.
        require(snapshotTs + minDelay <= block.timestamp, string.concat(symbol, ": carried snapshot is newer than MINIMUM_SNAPSHOT_DELAY"));
        require(snapshotTs + MAX_SNAPSHOT_TERM > block.timestamp, string.concat(symbol, ": carried snapshot is older than 180 days, re-snapshot required"));
        require(snapshotRatio <= type(uint104).max, string.concat(symbol, ": snapshot ratio overflows uint104"));
        require(snapshotTs <= type(uint48).max, string.concat(symbol, ": snapshot timestamp overflows uint48"));
        require(growthPercent <= type(uint16).max, string.concat(symbol, ": growth percent overflows uint16"));

        address rebuilt = address(
            new CLRatePriceCapAdapter(
                IPriceCapAdapter.CapAdapterParams({
                    aclManager: IACLManager(ACCESS_MANAGER),
                    baseAggregatorAddress: newBase,
                    ratioProviderAddress: ratioProvider,
                    pairDescription: live.description(),
                    minimumSnapshotDelay: minDelay,
                    priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
                        snapshotRatio: uint104(snapshotRatio),
                        snapshotTimestamp: uint48(snapshotTs),
                        maxYearlyRatioGrowthPercent: uint16(growthPercent)
                    })
                })
            )
        );

        // The cap must be a clone, not a re-tune. Compare every parameter that shapes the ceiling.
        IPriceCapAdapter fresh = IPriceCapAdapter(rebuilt);
        require(fresh.RATIO_PROVIDER() == ratioProvider, string.concat(symbol, ": ratio provider changed"));
        require(fresh.getSnapshotRatio() == snapshotRatio, string.concat(symbol, ": snapshot ratio changed"));
        require(fresh.getSnapshotTimestamp() == snapshotTs, string.concat(symbol, ": snapshot timestamp changed"));
        require(fresh.getMaxYearlyGrowthRatePercent() == growthPercent, string.concat(symbol, ": growth percent changed"));
        require(fresh.getMaxRatioGrowthPerSecondScaled() == live.getMaxRatioGrowthPerSecondScaled(), string.concat(symbol, ": derived growth per second changed"));
        require(fresh.getMaxRatioGrowthPerSecondScaled() > 0, string.concat(symbol, ": growth floored to zero, the ceiling would never rise"));
        require(fresh.RATIO_DECIMALS() == live.RATIO_DECIMALS(), string.concat(symbol, ": ratio decimals changed"));
        require(fresh.DECIMALS() == USD_FEED_DECIMALS, string.concat(symbol, ": cap base leg is not 8 decimals"));
        require(fresh.isCapped() == live.isCapped(), string.concat(symbol, ": cap binding state changed"));
        require(!fresh.isCapped(), string.concat(symbol, ": growth cap is binding, collateral would be under-priced"));
        _requireSamePrice(symbol, liveAdapter, rebuilt);

        console.log(string.concat("  adapter ", symbol, "  ", vm.toString(rebuilt), "  (rebuilt from ", vm.toString(liveAdapter), ")"));
        return rebuilt;
    }

    /// @dev Rebuilds the EUR par-cap adapter on the new EUR base. This one has no snapshot: the whole
    ///      cap is `priceCapRatio`, carried over verbatim along with the asset leg and description.
    function _rebuildEurStable(address liveAdapter, address newBase) internal returns (address) {
        IEURPriceCapAdapterStable live = IEURPriceCapAdapterStable(liveAdapter);

        address assetLeg = address(live.ASSET_TO_USD_AGGREGATOR());
        address liveBase = address(live.BASE_TO_USD_AGGREGATOR());
        require(liveBase != newBase, "EURC: live adapter already reads the new base");
        _requireSameAggregator("EURC", liveBase, newBase);

        int256 capRatio = live.getPriceCapRatio();
        uint8 ratioDecimals = live.RATIO_DECIMALS();
        require(capRatio == EURC_CAP_RATIO, "EURC: live price cap ratio is not the reviewed value");

        address rebuilt = address(
            new EURPriceCapAdapterStable(
                IEURPriceCapAdapterStable.CapAdapterStableParamsEUR({
                    aclManager: IACLManager(ACCESS_MANAGER),
                    assetToUsdAggregator: IChainlinkAggregator(assetLeg),
                    baseToUsdAggregator: IChainlinkAggregator(newBase),
                    adapterDescription: live.description(),
                    priceCapRatio: capRatio,
                    ratioDecimals: ratioDecimals
                })
            )
        );

        IEURPriceCapAdapterStable fresh = IEURPriceCapAdapterStable(rebuilt);
        require(address(fresh.ASSET_TO_USD_AGGREGATOR()) == assetLeg, "EURC: asset leg changed");
        require(fresh.getPriceCapRatio() == capRatio, "EURC: price cap ratio changed");
        require(fresh.RATIO_DECIMALS() == ratioDecimals, "EURC: ratio decimals changed");
        require(fresh.decimals() == USD_FEED_DECIMALS, "EURC: adapter decimals != 8");
        require(fresh.isCapped() == live.isCapped(), "EURC: cap binding state changed");
        _requireSamePrice("EURC", liveAdapter, rebuilt);

        console.log(string.concat("  adapter EURC  ", vm.toString(rebuilt), "  (rebuilt from ", vm.toString(liveAdapter), ")"));
        return rebuilt;
    }

    /// @dev The heart of the safety argument: the old and new base legs must be two wrappers over the
    ///      SAME Chainlink aggregator, differing only in the staleness bound. If they are not, this
    ///      run is silently changing where a price comes from, not how long it stays valid.
    function _requireSameAggregator(string memory symbol, address oldLeg, address newLeg) internal view {
        address oldAgg = address(ChainlinkPriceFeed(oldLeg).rateFeed());
        address newAgg = address(ChainlinkPriceFeed(newLeg).rateFeed());
        require(oldAgg == newAgg, string.concat(symbol, ": new base wraps a different aggregator than the live base"));
        require(
            ChainlinkPriceFeed(oldLeg).rateMaxStaleness() != ChainlinkPriceFeed(newLeg).rateMaxStaleness(),
            string.concat(symbol, ": new base has the same bound as the live one, nothing to change")
        );
    }

    /// @dev Exact equality, not a tolerance. Same aggregator, same ratio provider, same snapshot, same
    ///      block: any difference at all is a wiring bug.
    function _requireSamePrice(string memory symbol, address liveSource, address newSource) internal view {
        int256 before = ICLSynchronicityPriceAdapter(liveSource).latestAnswer();
        int256 nowPrice = ICLSynchronicityPriceAdapter(newSource).latestAnswer();
        require(before > 0, string.concat(symbol, ": live source returned a non-positive price"));
        require(
            nowPrice == before,
            string.concat(symbol, ": rebuilt source prices differently - live=", vm.toString(before), " new=", vm.toString(nowPrice))
        );
    }

    // ------------------------------------------------------------------ bookkeeping

    function _record(string memory symbol, address newSource, uint256 reserveId) internal {
        results.push(Result({ symbol: symbol, reserveId: reserveId, newSource: newSource, replaces: address(0), price: 0 }));
    }

    // ------------------------------------------------------------------ verification

    /// @dev Every check is fatal. A silently wrong price source is the worst failure mode this market
    ///      has, so the script refuses to finish rather than print a warning.
    function _verify() internal {
        console.log("");
        console.log("=== verification ===");
        uint256 reserveCount = ISpokeLike(SPOKE).getReserveCount();

        for (uint256 i; i < results.length; i++) {
            Result storage r = results[i];
            require(r.reserveId < reserveCount, string.concat(r.symbol, ": reserve id is not listed on the spoke"));

            r.replaces = IAaveOracleLike(AAVE_ORACLE).getReserveSource(r.reserveId);
            require(r.replaces != r.newSource, string.concat(r.symbol, ": reserve already reads the new source"));

            uint8 dec = ICLSynchronicityPriceAdapter(r.newSource).decimals();
            require(dec == USD_FEED_DECIMALS, string.concat(r.symbol, ": new source decimals != 8, AaveOracle would reject it"));

            int256 answer = ICLSynchronicityPriceAdapter(r.newSource).latestAnswer();
            require(answer > 0, string.concat(r.symbol, ": new source returned a non-positive price"));

            uint256 livePrice = IAaveOracleLike(AAVE_ORACLE).getReservePrice(r.reserveId);
            require(livePrice > 0, string.concat(r.symbol, ": the live reserve price is zero"));

            // casting is safe because `answer` is require'd positive just above
            // forge-lint: disable-next-line(unsafe-typecast)
            r.price = uint256(answer);
            require(
                r.price == livePrice,
                string.concat(r.symbol, ": new source disagrees with the live oracle - live=", vm.toString(livePrice), " new=", vm.toString(r.price))
            );

            console.log(string.concat("  ok ", r.symbol, "  reserve=", vm.toString(r.reserveId), "  price=", vm.toString(r.price), "  (exact match)"));
        }
    }

    // ------------------------------------------------------------------ dress rehearsal
    //
    // Mirrors the ether.fi launch pipeline in the aave-v4 repo (scripts/etherfi/launch.sh stage 2,
    // tests/etherfi/EtherfiCashLaunchFork.t.sol): execute the change in the OWNER SAFE'S OWN CONTEXT
    // against the real instance and real roles, verify the resulting state field by field, and share
    // that verifier with the post-execution check. `vm.snapshotState`/`vm.revertToState` is the same
    // idiom that repo uses to simulate and roll back (tests/helpers/spoke/MathHelpers.sol).
    //
    // Pranking as the Owner Safe bypasses the Safe's signature threshold but NOT the configurator's
    // role check, so this is a genuine test that the Safe holds role 400 — a missing role fails here
    // rather than after the signers have already collected signatures.

    enum Kind {
        DirectLeg,
        Growth,
        EurStable
    }

    struct Expect {
        uint256 reserveId;
        string symbol;
        address aggregator; // the Chainlink aggregator the base leg must wrap
        uint256 bound; // the staleness bound the base leg must carry AFTER this change
        Kind kind;
        uint104 snapRatio;
        uint48 snapTs;
        uint16 growth;
    }

    function _expectations() internal pure returns (Expect[7] memory e) {
        e[0] = Expect(RESERVE_ETHFI, "ETHFI", ETHFI_USD, NEW_FAST, Kind.DirectLeg, 0, 0, 0);
        e[1] = Expect(RESERVE_WHYPE, "wHYPE", HYPE_USD, NEW_FAST, Kind.DirectLeg, 0, 0, 0);
        e[2] = Expect(RESERVE_OP, "OP", OP_USD, NEW_FAST, Kind.DirectLeg, 0, 0, 0);
        e[3] = Expect(RESERVE_SETHFI, "sETHFI", ETHFI_USD, NEW_FAST, Kind.Growth, SNAP_SETHFI, SNAP_TS_SETHFI, GROWTH_SETHFI);
        e[4] = Expect(RESERVE_BEHYPE, "beHYPE", HYPE_USD, NEW_FAST, Kind.Growth, SNAP_BEHYPE, SNAP_TS_BEHYPE, GROWTH_BEHYPE);
        e[5] = Expect(RESERVE_WEEUR, "weEUR", EUR_USD, NEW_EUR, Kind.Growth, SNAP_WEEUR, SNAP_TS_WEEUR, GROWTH_WEEUR);
        e[6] = Expect(RESERVE_EURC, "EURC", EUR_USD, NEW_EUR, Kind.EurStable, 0, 0, 0);
    }

    /// @dev Replays the exact Safe batch on this fork, verifies the post-state, then rolls back so
    ///      nothing leaks into the broadcast.
    function _rehearse() internal {
        console.log("");
        console.log("=== dress rehearsal: Owner Safe executes the batch on this fork ===");

        uint256 snap = vm.snapshotState();

        for (uint256 i; i < results.length; i++) {
            vm.prank(OWNER_SAFE);
            ISpokeConfiguratorLike(SPOKE_CONFIGURATOR).updateReservePriceSource(SPOKE, results[i].reserveId, results[i].newSource);
        }

        for (uint256 i; i < results.length; i++) {
            require(
                IAaveOracleLike(AAVE_ORACLE).getReserveSource(results[i].reserveId) == results[i].newSource,
                string.concat(results[i].symbol, ": repoint did not take")
            );
        }

        uint256 checked = verifyLive();
        require(checked == results.length, "rehearsal: not every repointed reserve was verified");

        vm.revertToState(snap);

        // The rehearsal must leave no trace: the live sources are back to what the batch replaces.
        for (uint256 i; i < results.length; i++) {
            require(
                IAaveOracleLike(AAVE_ORACLE).getReserveSource(results[i].reserveId) == results[i].replaces,
                string.concat(results[i].symbol, ": rehearsal state did not roll back")
            );
        }

        console.log(string.concat("  ", vm.toString(checked), " repoints executed as the Owner Safe, verified, and rolled back"));
    }

    /**
     * @notice Field-by-field check that the live instance reads the relaxed sources with the reviewed
     *         cap parameters intact. Shared by the dress rehearsal above and runnable standalone AFTER
     *         the Owner Safe executes the batch:
     *
     *           source .env && FOUNDRY_PROFILE=aave-deploy forge script \
     *             scripts/aave-v4/RelaxLendStalenessBounds.s.sol:RelaxLendStalenessBounds \
     *             --sig 'verifyLive()' --rpc-url $OPTIMISM_RPC -v
     *
     * @dev Asserts PROPERTIES, never deployed addresses, so it works without being told what was
     *      deployed — and so it cannot be satisfied by a source that merely happens to sit at the
     *      expected address. Returns the number of reserves checked so a silent zero-iteration pass
     *      cannot read as success.
     */
    function verifyLive() public view returns (uint256 checked) {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        Expect[7] memory expects = _expectations();

        for (uint256 i; i < expects.length; i++) {
            Expect memory e = expects[i];
            address src = IAaveOracleLike(AAVE_ORACLE).getReserveSource(e.reserveId);
            require(src.code.length != 0, string.concat(e.symbol, ": live source has no code"));
            require(ICLSynchronicityPriceAdapter(src).decimals() == USD_FEED_DECIMALS, string.concat(e.symbol, ": live source decimals != 8"));
            require(IAaveOracleLike(AAVE_ORACLE).getReservePrice(e.reserveId) > 0, string.concat(e.symbol, ": live reserve price is not positive"));

            address baseLeg = src;
            if (e.kind == Kind.Growth) {
                IPriceCapAdapter cap = IPriceCapAdapter(src);
                baseLeg = address(cap.BASE_TO_USD_AGGREGATOR());
                require(cap.getSnapshotRatio() == e.snapRatio, string.concat(e.symbol, ": snapshot ratio is not the reviewed value"));
                require(cap.getSnapshotTimestamp() == e.snapTs, string.concat(e.symbol, ": snapshot timestamp is not the reviewed value"));
                require(cap.getMaxYearlyGrowthRatePercent() == e.growth, string.concat(e.symbol, ": growth percent is not the reviewed value"));
                require(cap.getMaxRatioGrowthPerSecondScaled() > 0, string.concat(e.symbol, ": growth floored to zero"));
                require(!cap.isCapped(), string.concat(e.symbol, ": growth cap is binding, collateral is under-priced"));
            } else if (e.kind == Kind.EurStable) {
                IEURPriceCapAdapterStable cap = IEURPriceCapAdapterStable(src);
                baseLeg = address(cap.BASE_TO_USD_AGGREGATOR());
                require(cap.getPriceCapRatio() == EURC_CAP_RATIO, string.concat(e.symbol, ": price cap ratio is not the reviewed value"));
            }

            // The point of the whole change: the base leg wraps the same aggregator as before and
            // now carries the relaxed bound.
            require(
                address(ChainlinkPriceFeed(baseLeg).rateFeed()) == e.aggregator,
                string.concat(e.symbol, ": base leg wraps the wrong aggregator")
            );
            require(
                ChainlinkPriceFeed(baseLeg).rateMaxStaleness() == e.bound,
                string.concat(e.symbol, ": base leg bound is not the relaxed value")
            );

            console.log(string.concat("  verified ", e.symbol, "  reserve=", vm.toString(e.reserveId), "  bound=", vm.toString(e.bound), "s"));
            checked++;
        }
    }

    // ------------------------------------------------------------------ hand-off

    function _printSafeBatch() internal view {
        console.log("");
        console.log("=== Owner Safe batch: SpokeConfigurator.updateReservePriceSource ===");
        console.log("target :", SPOKE_CONFIGURATOR);
        console.log("sender :", OWNER_SAFE, "(needs role 400)");
        console.log(string.concat("calls  : ", vm.toString(results.length)));

        for (uint256 i; i < results.length; i++) {
            Result storage r = results[i];
            console.log(string.concat("  reserve ", vm.toString(r.reserveId), "  ", r.symbol));
            console.log("    replaces", r.replaces);
            console.log(
                "    calldata",
                vm.toString(abi.encodeCall(ISpokeConfiguratorLike.updateReservePriceSource, (SPOKE, r.reserveId, r.newSource)))
            );
        }
    }

    /// @dev Emits the batch in the exact schema the 3CP-Secure repo takes, so the file drops straight
    ///      into `queued/644/optimism.json` with no reshaping. Matches 3CP-616
    ///      (`queued/616/optimism-repoint-price-adapters.json`) field for field — the same Safe, the
    ///      same target and the same `updateReservePriceSource` selector — which is what the hash
    ///      generation workflow and the offline signers consume.
    ///
    ///      ONLY THE FILE FROM A --broadcast RUN IS SUBMITTABLE. A dry run deploys into a simulated
    ///      EVM, so the addresses it writes here do not exist on chain.
    function _writeSafeBatchJson() internal {
        string memory json = string.concat(
            '{\n  "chainId": "10",\n  "safeAddress": "', vm.toString(OWNER_SAFE), '",\n', '  "meta": {\n    "txBuilderVersion": "1.16.5"\n  },\n  "transactions": [\n'
        );
        for (uint256 i; i < results.length; i++) {
            json = string.concat(
                json,
                '    {\n      "to": "',
                vm.toString(SPOKE_CONFIGURATOR),
                '",\n      "value": "0",\n      "data": "',
                vm.toString(abi.encodeCall(ISpokeConfiguratorLike.updateReservePriceSource, (SPOKE, results[i].reserveId, results[i].newSource))),
                '"\n    }',
                i + 1 == results.length ? "\n" : ",\n"
            );
        }
        json = string.concat(json, "  ]\n}\n");
        vm.writeFile("output/3CP-644-RelaxLendStaleness-10.json", json);
        console.log("");
        console.log("wrote output/3CP-644-RelaxLendStaleness-10.json  (drop-in for 3CP-Secure queued/644/optimism.json)");
        console.log("  !! only submit this file if it came from a --broadcast run !!");
    }

    function _writeJson() internal {
        string memory json = "{";
        json = string.concat(json, '"aclManager":"', vm.toString(ACCESS_MANAGER), '"');
        for (uint256 i; i < results.length; i++) {
            json = string.concat(
                json,
                ',"',
                results[i].symbol,
                '":{"reserveId":"',
                vm.toString(results[i].reserveId),
                '","source":"',
                vm.toString(results[i].newSource),
                '","replaces":"',
                vm.toString(results[i].replaces),
                '","price":"',
                vm.toString(results[i].price),
                '"}'
            );
        }
        json = string.concat(json, "}");
        vm.writeFile("output/RelaxedStalenessFeedsOP.json", json);
        console.log("wrote output/RelaxedStalenessFeedsOP.json");
    }
}
