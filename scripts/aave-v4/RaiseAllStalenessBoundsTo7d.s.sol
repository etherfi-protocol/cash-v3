// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IOracleSink } from "../../src/interfaces/IOracleSink.sol";
import { IVedaAccountant } from "../../src/interfaces/IVedaAccountant.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { OracleSinkPriceFeed } from "../../src/oracle/OracleSinkPriceFeed.sol";
import { VedaAccountantPriceFeed } from "../../src/oracle/VedaAccountantPriceFeed.sol";
import { CLRatePriceCapAdapter } from "../../src/oracle/capo/vendor/CLRatePriceCapAdapter.sol";
import { EURPriceCapAdapterStable } from "../../src/oracle/capo/vendor/EURPriceCapAdapterStable.sol";
import { IACLManager } from "../../src/oracle/capo/vendor/IACLManager.sol";
import { IChainlinkAggregator } from "../../src/oracle/capo/vendor/IChainlinkAggregator.sol";
import { ICLSynchronicityPriceAdapter } from "../../src/oracle/capo/vendor/ICLSynchronicityPriceAdapter.sol";
import { IEURPriceCapAdapterStable } from "../../src/oracle/capo/vendor/IEURPriceCapAdapterStable.sol";
import { IPriceCapAdapter } from "../../src/oracle/capo/vendor/IPriceCapAdapter.sol";
import { IPriceCapAdapterStable } from "../../src/oracle/capo/vendor/IPriceCapAdapterStable.sol";
import { PriceCapAdapterStable } from "../../src/oracle/capo/vendor/PriceCapAdapterStable.sol";

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
 * @title RaiseAllStalenessBoundsTo7d
 * @notice 3CP-657. Raises EVERY staleness bound on the prod Summer Lend (Aave v4) instance on OP
 *         Mainnet to a uniform minimum of 7 days, and rebuilds every cap adapter that bakes a
 *         changed leg in immutably.
 *
 *         Scope, derived by walking all 23 reserves' sources down to the leaves rather than from a
 *         manifest: 29 bounded legs exist on the instance, 25 sit below 7 days. Rebuilding those 25
 *         forces a rebuild of the 12 cap adapters above them, and 20 of the 23 reserves get
 *         repointed. Reserves 16 (liquidRESERVE), 17 (weEUR) and 18 (liquidRWA) are already at 7d
 *         throughout and are not touched.
 *
 *         RATIONALE, AND THE LIMIT OF IT. The operating decision here is that price-feed health is
 *         monitored actively off chain and acted on regardless of the on-chain bound, so the bound is
 *         a backstop rather than the primary control. Under that model a uniform 7d floor removes a
 *         class of self-inflicted liveness outages: a merely-late feed no longer fails a reserve
 *         closed, and every asset browns out on the same schedule instead of a different one per leg.
 *
 *         What it costs is real and is recorded here so it is not rediscovered later. For a KEEPER
 *         leg (Veda accountant) the exposure is tiny: those rates are monotone accruals drifting
 *         <1.5 bps/day, so a frozen rate held the extra days mis-prices by single-digit bps. For a
 *         MARKET leg the exposure is the worst adverse price move over the wider window, measured on
 *         ~150 days of aggregator history:
 *
 *           feed          worst move at 48h / at 7d / delta
 *           ETHFI / USD        28.48%  ->  54.84%   (+26.36pp)
 *           HYPE  / USD        27.79%  ->  34.28%    (+6.49pp)
 *           ETH   / USD        23.48%  ->  26.24%    (+2.76pp)
 *           OP    / USD        19.03%  ->  19.74%    (+0.71pp)
 *           BTC   / USD        13.73%  ->  16.71%    (+2.98pp)
 *
 *         Against bad-debt tolerance `1 - 1/(1+bonus)` from the LT trigger: 13.04% on
 *         liquidETH/liquidBTC (CF 70%, bonus 1.150x), 6.98% on liquidUSD/eUSD (CF 90%, 1.075x),
 *         16.67% on sETHFI (CF 40%, 1.200x). So on a genuinely DEAD market feed a 7d bound can serve
 *         a stale price past the point where liquidations stop covering the position. None of the
 *         market aggregators has ever breached even its current bound (max observed gap 0.34h on
 *         ETH/USD and BTC/USD against 48h), so this widening is not fixing an observed problem on
 *         those legs — it is accepting a larger backstop window in exchange for uniformity, and it
 *         relies on the off-chain monitor to catch a dead feed long before 7 days.
 *
 *         The keeper legs are the ones with a real observed problem, and they are fixed by this:
 *         liquidETH breached 48h six times (worst 96.76h), eBTC five times (worst 624.04h), sETHFI
 *         four, eUSD twice, liquidBTC and liquidUSD once each. eBTC and sETHFI still breach at 7d
 *         (624h and 170h gaps); 7d is a strict improvement for them, not a fix.
 *
 *         WHY A REDEPLOY AND NOT A SETTER. `rateMaxStaleness` is immutable on all three of our feed
 *         types, and Aave's cap adapters hold their legs immutable with the cap setters permanently
 *         unreachable on this instance (the ACL manager is the AccessManager, which implements
 *         neither `isRiskAdmin` nor `isPoolAdmin`). A new bound needs a new leg, and a new leg needs
 *         a rebuild of every adapter sitting on it.
 *
 *         NOTHING BUT THE BOUND CHANGES. Every new leg wraps the same aggregator / accountant / sink
 *         and token as the leg it replaces, carries its description across verbatim, and keeps
 *         `isStableToken` and the rate precision identical. Every rebuilt adapter reuses the same
 *         siblings and carries the same cap parameters forward, read off the live adapter rather than
 *         restated. Shared legs are deployed ONCE and reused, so the pre-change sharing graph is
 *         preserved exactly: ETH/USD is shared by weETH and liquidETH, BTC/USD by eBTC and
 *         liquidBTC, USDC/USD by USDC and liquidUSD, ETHFI/USD by ETHFI and sETHFI, HYPE/USD by
 *         wHYPE and beHYPE. Duplicate legs that exist today (WETH reads its own ETH/USD leg,
 *         distinct from the one weETH/liquidETH read) are kept duplicated rather than consolidated,
 *         because consolidating them would be a wiring change beyond this batch.
 *
 *         `_verify` asserts every new source prices EXACTLY equal to the one it replaces, to the wei.
 *
 * Usage — dry run first (no --broadcast), which still runs every assertion:
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RaiseAllStalenessBoundsTo7d.s.sol:RaiseAllStalenessBoundsTo7d \
 *     --rpc-url $OPTIMISM_RPC --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e -vvv
 *
 * Then broadcast and verify:
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RaiseAllStalenessBoundsTo7d.s.sol:RaiseAllStalenessBoundsTo7d \
 *     --rpc-url $OPTIMISM_RPC --account etherfi-deployer \
 *     --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 */
contract RaiseAllStalenessBoundsTo7d is Script {
    // ---------------------------------------------------------------- instance (OP Mainnet)
    address constant ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
    address constant SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    address constant OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

    /// @notice The uniform floor every bound is raised to.
    uint256 constant TARGET = 7 days;

    /// @dev The floor `verifyLive` checks against, deliberately a SEPARATE literal from `TARGET`.
    ///      If the post-state check reused `TARGET`, lowering `TARGET` would move both the setter and
    ///      the assertion together and the check would pass tautologically — verified: setting
    ///      `TARGET = 5 days` produced a fully green run. Pinning the audited floor independently
    ///      means a change to the deployed bound has to be reflected here on purpose.
    uint256 constant REQUIRED_FLOOR = 604800; // 7 days, the value this change was reviewed at

    uint8 constant USD_FEED_DECIMALS = 8;

    /// @dev Aave's `PriceCapAdapterBase` rejects a snapshot older than this.
    uint48 constant MAX_SNAPSHOT_TERM = 180 days;

    // ---------------------------------------------------------------- live legs below 7d
    // Every one of these is replaced by a same-wiring leg at TARGET. Ordered as in the plan output.
    address constant L_ETHFI_USD     = 0x53c3d3c36cae804E6B639cA2600662aF51B4fFc9; //  36h
    address constant L_HYPE_USD      = 0xB41cE833937aEf200B77fa796bADED2F6Bea7D82; //  36h
    address constant L_OP_USD        = 0x3b79488486f0aD5F05a66Ad377E25b829fff2bD5; //  36h
    address constant L_BTC_USD       = 0x7F5276E01c62490C67490BB6515Ed075F813Ac50; //  48h
    address constant L_ETH_USD_WETH  = 0xCFe45EF2B9E138E5A2e1C25592441D5c556B3ca3; //  48h, reserve 1 only
    address constant L_ETH_USD_SHARED= 0x62B6153a877b0Eb64A94F132b04D3Afb018c0d16; //  48h, weETH + liquidETH
    address constant L_EURC_USD      = 0x1fF6e0FBd92038BDD7dA83A62A45C5E1D036A237; //  48h
    address constant L_USDC_USD      = 0xADfA1a2BC18d76176735ac8E3277A351663fa19B; //  48h, USDC + liquidUSD
    address constant L_USDT_USD      = 0xfd503fdB6d37bC1e864b4B58f787F0A3F704402c; //  48h
    address constant L_FRXUSD_USD    = 0xe6e0fe0C3Ac45d1FE71AF7853007467eE89e1e67; //  48h
    address constant L_BEHYPE_RATE   = 0xcd0D452cDbaD335a7423299dC0EE0f544e5FfD96; //  48h, 18 dec
    address constant L_WEETH_RATE    = 0xA9E4936d025eB904a767f6F0c16f38c5C2016711; //  48h, 18 dec
    address constant L_PAXG_USD      = 0x7DC0EAff1ECaED8A8A5aDC07dEe1997fF4617800; //  72h
    address constant L_QQQ_USD       = 0x459E1D5e587eB81bA25C6AA1e817e40bd36fb2F4; //  72h
    address constant L_SPY_USD       = 0x045ACc54e73f93c5b9B4F20Fa01931cB23234C38; //  72h
    address constant L_TBLL_USD      = 0x1A74F66b6CF21b582C316398925b24D3D04C8C7D; //  72h

    address constant V_EBTC_RATE      = 0xAd6ad4a8647c60C17E0B4eA9f78e8b663EC35599; // 48h Veda
    address constant V_EUSD_RATE      = 0x311486d71761Caf9d68f6F03bf1d8c05c01bB863; // 48h Veda
    address constant V_LIQUID_BTC_RATE= 0x60BE06699ABe614E0FbA99eC11a1CDa6B2238755; // 48h Veda
    address constant V_LIQUID_ETH_RATE= 0x1305D82Ce705b4E73bF22E5548c6cF90bA1735Db; // 48h Veda
    address constant V_LIQUID_USD_RATE= 0x0C5631727ECF13f3e726Bc3301E364Af51b69295; // 48h Veda
    address constant V_SETHFI_RATE    = 0xb1F53B6aA18205bb8E468EC6a8cF3b8194ed5d7E; // 48h Veda

    address constant S_IWSPYX  = 0x253F4Fb7082e314430972A2B783aD7514D20d64c; // 72h sink feed
    address constant S_IWQQQX  = 0xb5f61BDfCa60c02d13377d4386288FE143b9d6bE; // 72h sink feed
    address constant S_IWTBLLX = 0x1cee92F999D536320aFb740b2ea5318C45d9C93B; // 72h sink feed

    // ---------------------------------------------------------------- live adapters to rebuild
    address constant A_USDC      = 0xE55eacdC1EC9dA0f33B9CEa7D136a47CC6008C69; // stable
    address constant A_USDT      = 0x6a6B2529c1BC14f0A062D7903B4894B477BfFc92; // stable
    address constant A_FRXUSD    = 0x859c126dad6952a798ecdc5c06f7063B8a9FCC31; // stable
    address constant A_EURC      = 0xC1Cf424A5d58BB943aDbA7fF3E1E1D2e354C2CD1; // EUR stable
    address constant A_WEETH     = 0x81ED135fc10FF855202E582d8cfd50E8A5533fd9; // CLRate
    address constant A_EBTC      = 0xFa80bA4b7aC946F3b45DC8ED537b1BEbD8eC860f; // CLRate
    address constant A_EUSD      = 0xD617E1D59aA992D985c07ADC48c36aD2a00E751b; // CLRate
    address constant A_SETHFI    = 0xd452ca984E0606297bCb430e076087F126e24a38; // CLRate
    address constant A_BEHYPE    = 0xc6d0023679769A532879AE50E57F40aB628201E7; // CLRate
    address constant A_LIQUID_ETH= 0x48420d702a3190235B5A5D123ca82f876752add1; // CLRate
    address constant A_LIQUID_BTC= 0xD60ec8fCba09c7642099eA89A9D58721B00277C7; // CLRate
    address constant A_LIQUID_USD= 0x17DdE04d8Ff1024D3076944658ED9B6bd5F51451; // CLRate

    // ---------------------------------------------------------------- reserve ids
    uint256 constant R_USDC = 0;
    uint256 constant R_WETH = 1;
    uint256 constant R_USDT = 2;
    uint256 constant R_EURC = 3;
    uint256 constant R_FRXUSD = 4;
    uint256 constant R_WEETH = 5;
    uint256 constant R_EBTC = 6;
    uint256 constant R_EUSD = 7;
    uint256 constant R_ETHFI = 8;
    uint256 constant R_SETHFI = 9;
    uint256 constant R_OP = 10;
    uint256 constant R_WHYPE = 11;
    uint256 constant R_BEHYPE = 12;
    uint256 constant R_LIQUID_ETH = 13;
    uint256 constant R_LIQUID_BTC = 14;
    uint256 constant R_LIQUID_USD = 15;
    uint256 constant R_IWSPYX = 19;
    uint256 constant R_IPAXG = 20;
    uint256 constant R_IWQQQX = 21;
    uint256 constant R_IWTBLLX = 22;

    struct Result {
        string symbol;
        uint256 reserveId;
        address newSource;
        address replaces;
        uint256 price;
    }

    Result[] internal results;

    /// @dev old leg -> new leg, so a leg shared by two reserves is deployed exactly once and the
    ///      pre-change sharing graph is preserved.
    mapping(address => address) internal rebuilt;
    address[] internal rebuiltKeys;

    /// @dev Captured once before anything warps the clock. See `_proveBoundsMoved`.
    uint256 internal forkTimestamp;

    function run() public {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        require(ACCESS_MANAGER.code.length != 0, "no code at the AccessManager");
        forkTimestamp = block.timestamp;

        vm.startBroadcast();

        // ---- legs, each deployed once and memoised
        _chainlinkLeg(L_ETHFI_USD);
        _chainlinkLeg(L_HYPE_USD);
        _chainlinkLeg(L_OP_USD);
        _chainlinkLeg(L_BTC_USD);
        _chainlinkLeg(L_ETH_USD_WETH);
        _chainlinkLeg(L_ETH_USD_SHARED);
        _chainlinkLeg(L_EURC_USD);
        _chainlinkLeg(L_USDC_USD);
        _chainlinkLeg(L_USDT_USD);
        _chainlinkLeg(L_FRXUSD_USD);
        _chainlinkLeg(L_BEHYPE_RATE);
        _chainlinkLeg(L_WEETH_RATE);
        _chainlinkLeg(L_PAXG_USD);
        _chainlinkLeg(L_QQQ_USD);
        _chainlinkLeg(L_SPY_USD);
        _chainlinkLeg(L_TBLL_USD);

        _vedaLeg(V_EBTC_RATE);
        _vedaLeg(V_EUSD_RATE);
        _vedaLeg(V_LIQUID_BTC_RATE);
        _vedaLeg(V_LIQUID_ETH_RATE);
        _vedaLeg(V_LIQUID_USD_RATE);
        _vedaLeg(V_SETHFI_RATE);

        // The sink feeds compose an underlying USD leg, so their underlying must exist first.
        _sinkLeg(S_IWSPYX, L_SPY_USD);
        _sinkLeg(S_IWQQQX, L_QQQ_USD);
        _sinkLeg(S_IWTBLLX, L_TBLL_USD);

        // ---- reserves reading a leg directly
        _record("WETH", _at(L_ETH_USD_WETH), R_WETH);
        _record("ETHFI", _at(L_ETHFI_USD), R_ETHFI);
        _record("OP", _at(L_OP_USD), R_OP);
        _record("wHYPE", _at(L_HYPE_USD), R_WHYPE);
        _record("iPAXG", _at(L_PAXG_USD), R_IPAXG);
        _record("iwSPYx", _at(S_IWSPYX), R_IWSPYX);
        _record("iwQQQx", _at(S_IWQQQX), R_IWQQQX);
        _record("iwTBLLx", _at(S_IWTBLLX), R_IWTBLLX);

        // ---- stable par-cap adapters
        _record("USDC", _rebuildStable(A_USDC, "USDC"), R_USDC);
        _record("USDT", _rebuildStable(A_USDT, "USDT"), R_USDT);
        _record("frxUSD", _rebuildStable(A_FRXUSD, "frxUSD"), R_FRXUSD);
        _record("EURC", _rebuildEurStable(A_EURC), R_EURC);

        // ---- growth cap adapters
        _record("weETH", _rebuildGrowth(A_WEETH, "weETH"), R_WEETH);
        _record("eBTC", _rebuildGrowth(A_EBTC, "eBTC"), R_EBTC);
        _record("eUSD", _rebuildGrowth(A_EUSD, "eUSD"), R_EUSD);
        _record("sETHFI", _rebuildGrowth(A_SETHFI, "sETHFI"), R_SETHFI);
        _record("beHYPE", _rebuildGrowth(A_BEHYPE, "beHYPE"), R_BEHYPE);
        _record("liquidETH", _rebuildGrowth(A_LIQUID_ETH, "liquidETH"), R_LIQUID_ETH);
        _record("liquidBTC", _rebuildGrowth(A_LIQUID_BTC, "liquidBTC"), R_LIQUID_BTC);
        _record("liquidUSD", _rebuildGrowth(A_LIQUID_USD, "liquidUSD"), R_LIQUID_USD);

        vm.stopBroadcast();

        _verify();
        _rehearse();
        _printSafeBatch();
        _writeSafeBatchJson();
        _writeJson();
    }

    // ------------------------------------------------------------------ leg builders

    function _at(address oldLeg) internal view returns (address a) {
        a = rebuilt[oldLeg];
        require(a != address(0), "leg was never rebuilt");
    }

    /// @dev Common pre-checks for any leg we replace: it must be below the target (else this run is
    ///      widening something that does not need it) and it must be one of our feeds.
    function _preLeg(address oldLeg, string memory what) internal view returns (uint256 oldBound) {
        require(rebuilt[oldLeg] == address(0), string.concat(what, ": leg already rebuilt in this run"));
        oldBound = ChainlinkPriceFeed(oldLeg).rateMaxStaleness();
        require(oldBound < TARGET, string.concat(what, ": live bound is already at or above the target"));
        require(!ChainlinkPriceFeed(oldLeg).isStableToken(), string.concat(what, ": live leg snaps to $1, the replacement would not match"));
    }

    function _postLeg(address oldLeg, address newLeg, string memory what) internal {
        require(ChainlinkPriceFeed(newLeg).rateMaxStaleness() == TARGET, string.concat(what, ": bound did not take"));
        require(ChainlinkPriceFeed(newLeg).decimals() == ChainlinkPriceFeed(oldLeg).decimals(), string.concat(what, ": feed decimals changed"));
        // Same source, same block: the answer must match to the wei.
        int256 before = IAaveV4PriceFeed(oldLeg).latestAnswer();
        int256 now_ = IAaveV4PriceFeed(newLeg).latestAnswer();
        require(before > 0, string.concat(what, ": live leg returned a non-positive answer"));
        require(now_ == before, string.concat(what, ": rebuilt leg differs - live=", vm.toString(before), " new=", vm.toString(now_)));
        rebuilt[oldLeg] = newLeg;
        rebuiltKeys.push(oldLeg);
        console.log(string.concat("  leg ", ChainlinkPriceFeed(oldLeg).description(), "  ", vm.toString(newLeg), "  (was ", vm.toString(oldLeg), ")"));
    }

    function _chainlinkLeg(address oldLeg) internal {
        ChainlinkPriceFeed live = ChainlinkPriceFeed(oldLeg);
        string memory what = live.description();
        _preLeg(oldLeg, what);
        address under = address(live.underlyingUsdFeed());
        // A composing Chainlink leg would need its underlying remapped; none exist on this instance.
        require(under == address(0), string.concat(what, ": chainlink leg composes an underlying, unsupported by this run"));
        address newLeg = address(
            new ChainlinkPriceFeed(live.rateFeed(), IAaveV4PriceFeed(address(0)), live.decimals(), TARGET, false, what)
        );
        require(address(ChainlinkPriceFeed(newLeg).rateFeed()) == address(live.rateFeed()), string.concat(what, ": new leg wraps a different aggregator"));
        _postLeg(oldLeg, newLeg, what);
    }

    function _vedaLeg(address oldLeg) internal {
        VedaAccountantPriceFeed live = VedaAccountantPriceFeed(oldLeg);
        string memory what = live.description();
        _preLeg(oldLeg, what);
        require(address(live.underlyingUsdFeed()) == address(0), string.concat(what, ": veda leg composes an underlying, unsupported by this run"));
        address newLeg = address(
            new VedaAccountantPriceFeed(live.accountant(), IAaveV4PriceFeed(address(0)), live.decimals(), TARGET, false, what)
        );
        require(address(VedaAccountantPriceFeed(newLeg).accountant()) == address(live.accountant()), string.concat(what, ": new leg reads a different accountant"));
        _postLeg(oldLeg, newLeg, what);
    }

    /// @dev A sink feed composes an underlying USD leg, which this run also replaces, so the new sink
    ///      feed must point at the NEW underlying. That makes its price identity a two-part claim:
    ///      same sink+token, and an underlying that itself already proved wei-equality.
    function _sinkLeg(address oldLeg, address oldUnderlying) internal {
        OracleSinkPriceFeed live = OracleSinkPriceFeed(oldLeg);
        string memory what = live.description();
        _preLeg(oldLeg, what);
        require(address(live.underlyingUsdFeed()) == oldUnderlying, string.concat(what, ": live sink feed composes a different underlying than this run assumes"));
        address newUnderlying = _at(oldUnderlying);
        address newLeg = address(
            new OracleSinkPriceFeed(live.sink(), live.token(), IAaveV4PriceFeed(newUnderlying), live.decimals(), TARGET, false, what)
        );
        OracleSinkPriceFeed fresh = OracleSinkPriceFeed(newLeg);
        require(address(fresh.sink()) == address(live.sink()), string.concat(what, ": new sink feed reads a different sink"));
        require(fresh.token() == live.token(), string.concat(what, ": new sink feed prices a different token"));
        require(address(fresh.underlyingUsdFeed()) == newUnderlying, string.concat(what, ": new sink feed composes the wrong underlying"));
        _postLeg(oldLeg, newLeg, what);
    }

    // ------------------------------------------------------------------ adapter rebuilds

    /// @dev `PriceCapAdapterStable`: one asset leg, a flat par cap, no snapshot.
    function _rebuildStable(address liveAdapter, string memory symbol) internal returns (address) {
        IPriceCapAdapterStable live = IPriceCapAdapterStable(liveAdapter);
        address newAsset = _at(address(live.ASSET_TO_USD_AGGREGATOR()));
        int256 cap = live.getPriceCap();
        require(cap > 0, string.concat(symbol, ": live price cap is not positive"));

        address rebuiltAdapter = address(
            new PriceCapAdapterStable(
                IPriceCapAdapterStable.CapAdapterStableParams({
                    aclManager: IACLManager(ACCESS_MANAGER),
                    assetToUsdAggregator: IChainlinkAggregator(newAsset),
                    adapterDescription: live.description(),
                    priceCap: cap
                })
            )
        );
        IPriceCapAdapterStable fresh = IPriceCapAdapterStable(rebuiltAdapter);
        require(address(fresh.ASSET_TO_USD_AGGREGATOR()) == newAsset, string.concat(symbol, ": asset leg did not take"));
        require(fresh.getPriceCap() == cap, string.concat(symbol, ": price cap changed"));
        require(fresh.decimals() == USD_FEED_DECIMALS, string.concat(symbol, ": adapter decimals != 8"));
        require(fresh.isCapped() == live.isCapped(), string.concat(symbol, ": cap binding state changed"));
        _requireSamePrice(symbol, liveAdapter, rebuiltAdapter);
        console.log(string.concat("  adapter ", symbol, "  ", vm.toString(rebuiltAdapter), "  (rebuilt from ", vm.toString(liveAdapter), ")"));
        return rebuiltAdapter;
    }

    /// @dev `EURPriceCapAdapterStable`: an asset leg over a base leg, with a par cap RATIO. The base
    ///      (EUR/USD) is already at 7d on this instance, so it is reused untouched.
    function _rebuildEurStable(address liveAdapter) internal returns (address) {
        IEURPriceCapAdapterStable live = IEURPriceCapAdapterStable(liveAdapter);
        address liveBase = address(live.BASE_TO_USD_AGGREGATOR());
        require(rebuilt[liveBase] == address(0), "EURC: base leg was rebuilt, this path assumes it is reused untouched");
        require(ChainlinkPriceFeed(liveBase).rateMaxStaleness() >= TARGET, "EURC: base leg is below target and must be rebuilt");
        address newAsset = _at(address(live.ASSET_TO_USD_AGGREGATOR()));
        int256 capRatio = live.getPriceCapRatio();
        uint8 ratioDecimals = live.RATIO_DECIMALS();
        require(capRatio > 0, "EURC: live price cap ratio is not positive");

        address rebuiltAdapter = address(
            new EURPriceCapAdapterStable(
                IEURPriceCapAdapterStable.CapAdapterStableParamsEUR({
                    aclManager: IACLManager(ACCESS_MANAGER),
                    assetToUsdAggregator: IChainlinkAggregator(newAsset),
                    baseToUsdAggregator: IChainlinkAggregator(liveBase),
                    adapterDescription: live.description(),
                    priceCapRatio: capRatio,
                    ratioDecimals: ratioDecimals
                })
            )
        );
        IEURPriceCapAdapterStable fresh = IEURPriceCapAdapterStable(rebuiltAdapter);
        require(address(fresh.ASSET_TO_USD_AGGREGATOR()) == newAsset, "EURC: asset leg did not take");
        require(address(fresh.BASE_TO_USD_AGGREGATOR()) == liveBase, "EURC: base leg changed");
        require(fresh.getPriceCapRatio() == capRatio, "EURC: price cap ratio changed");
        require(fresh.RATIO_DECIMALS() == ratioDecimals, "EURC: ratio decimals changed");
        require(fresh.decimals() == USD_FEED_DECIMALS, "EURC: adapter decimals != 8");
        require(fresh.isCapped() == live.isCapped(), "EURC: cap binding state changed");
        _requireSamePrice("EURC", liveAdapter, rebuiltAdapter);
        console.log(string.concat("  adapter EURC  ", vm.toString(rebuiltAdapter), "  (rebuilt from ", vm.toString(liveAdapter), ")"));
        return rebuiltAdapter;
    }

    /// @dev `CLRatePriceCapAdapter`: base x ratio with a growth cap. Either or both legs may have
    ///      been rebuilt; a leg that was NOT rebuilt (the OneUSDFixedAdapter under eUSD) is reused as
    ///      is. The cap snapshot is carried forward verbatim and asserted unchanged.
    function _rebuildGrowth(address liveAdapter, string memory symbol) internal returns (address) {
        IPriceCapAdapter live = IPriceCapAdapter(liveAdapter);

        address liveBase = address(live.BASE_TO_USD_AGGREGATOR());
        address liveRatio = live.RATIO_PROVIDER();
        address newBase = rebuilt[liveBase] == address(0) ? liveBase : rebuilt[liveBase];
        address newRatio = rebuilt[liveRatio] == address(0) ? liveRatio : rebuilt[liveRatio];
        require(newBase != liveBase || newRatio != liveRatio, string.concat(symbol, ": neither leg changed, nothing to rebuild"));

        uint256 snapshotRatio = live.getSnapshotRatio();
        uint256 snapshotTs = live.getSnapshotTimestamp();
        uint256 growthPercent = live.getMaxYearlyGrowthRatePercent();
        uint48 minDelay = live.MINIMUM_SNAPSHOT_DELAY();

        // Aave's `_setCapParameters` window. Failing here means the carried snapshot has aged out and
        // a fresh one must be taken and risk-reviewed — do NOT paper over it by loosening the growth.
        require(snapshotTs + minDelay <= block.timestamp, string.concat(symbol, ": carried snapshot is newer than MINIMUM_SNAPSHOT_DELAY"));
        require(snapshotTs + MAX_SNAPSHOT_TERM > block.timestamp, string.concat(symbol, ": carried snapshot is older than 180 days, re-snapshot required"));
        require(snapshotRatio <= type(uint104).max, string.concat(symbol, ": snapshot ratio overflows uint104"));
        require(snapshotTs <= type(uint48).max, string.concat(symbol, ": snapshot timestamp overflows uint48"));
        require(growthPercent <= type(uint16).max, string.concat(symbol, ": growth percent overflows uint16"));

        address rebuiltAdapter = address(
            new CLRatePriceCapAdapter(
                IPriceCapAdapter.CapAdapterParams({
                    aclManager: IACLManager(ACCESS_MANAGER),
                    baseAggregatorAddress: newBase,
                    ratioProviderAddress: newRatio,
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

        // The cap must be a clone, not a re-tune.
        IPriceCapAdapter fresh = IPriceCapAdapter(rebuiltAdapter);
        require(address(fresh.BASE_TO_USD_AGGREGATOR()) == newBase, string.concat(symbol, ": base leg did not take"));
        require(fresh.RATIO_PROVIDER() == newRatio, string.concat(symbol, ": ratio leg did not take"));
        require(fresh.getSnapshotRatio() == snapshotRatio, string.concat(symbol, ": snapshot ratio changed"));
        require(fresh.getSnapshotTimestamp() == snapshotTs, string.concat(symbol, ": snapshot timestamp changed"));
        require(fresh.getMaxYearlyGrowthRatePercent() == growthPercent, string.concat(symbol, ": growth percent changed"));
        require(fresh.getMaxRatioGrowthPerSecondScaled() == live.getMaxRatioGrowthPerSecondScaled(), string.concat(symbol, ": derived growth per second changed"));
        require(fresh.getMaxRatioGrowthPerSecondScaled() > 0, string.concat(symbol, ": growth floored to zero, the ceiling would never rise"));
        require(fresh.RATIO_DECIMALS() == live.RATIO_DECIMALS(), string.concat(symbol, ": ratio decimals changed"));
        require(fresh.DECIMALS() == USD_FEED_DECIMALS, string.concat(symbol, ": cap base leg is not 8 decimals"));
        require(fresh.isCapped() == live.isCapped(), string.concat(symbol, ": cap binding state changed"));
        require(!fresh.isCapped(), string.concat(symbol, ": growth cap is binding, collateral would be under-priced"));
        _requireSamePrice(symbol, liveAdapter, rebuiltAdapter);
        console.log(string.concat("  adapter ", symbol, "  ", vm.toString(rebuiltAdapter), "  (rebuilt from ", vm.toString(liveAdapter), ")"));
        return rebuiltAdapter;
    }

    /// @dev Exact equality, not a tolerance: same sources, same snapshot, same block.
    function _requireSamePrice(string memory symbol, address liveSource, address newSource) internal view {
        int256 before = ICLSynchronicityPriceAdapter(liveSource).latestAnswer();
        int256 nowPrice = ICLSynchronicityPriceAdapter(newSource).latestAnswer();
        require(before > 0, string.concat(symbol, ": live source returned a non-positive price"));
        require(
            nowPrice == before,
            string.concat(symbol, ": rebuilt source prices differently - live=", vm.toString(before), " new=", vm.toString(nowPrice))
        );
    }

    function _record(string memory symbol, address newSource, uint256 reserveId) internal {
        results.push(Result({ symbol: symbol, reserveId: reserveId, newSource: newSource, replaces: address(0), price: 0 }));
    }

    // ------------------------------------------------------------------ verification

    function _verify() internal {
        console.log("");
        console.log("=== verification ===");
        uint256 reserveCount = ISpokeLike(SPOKE).getReserveCount();

        for (uint256 i; i < results.length; i++) {
            Result storage r = results[i];
            require(r.reserveId < reserveCount, string.concat(r.symbol, ": reserve id is not listed on the spoke"));

            r.replaces = IAaveOracleLike(AAVE_ORACLE).getReserveSource(r.reserveId);
            require(r.replaces != r.newSource, string.concat(r.symbol, ": reserve already reads the new source"));

            require(ICLSynchronicityPriceAdapter(r.newSource).decimals() == USD_FEED_DECIMALS, string.concat(r.symbol, ": new source decimals != 8, AaveOracle would reject it"));

            int256 answer = ICLSynchronicityPriceAdapter(r.newSource).latestAnswer();
            require(answer > 0, string.concat(r.symbol, ": new source returned a non-positive price"));

            uint256 livePrice = IAaveOracleLike(AAVE_ORACLE).getReservePrice(r.reserveId);
            require(livePrice > 0, string.concat(r.symbol, ": the live reserve price is zero"));

            // forge-lint: disable-next-line(unsafe-typecast)
            r.price = uint256(answer);
            require(
                r.price == livePrice,
                string.concat(r.symbol, ": new source disagrees with the live oracle - live=", vm.toString(livePrice), " new=", vm.toString(r.price))
            );
            console.log(string.concat("  ok ", r.symbol, "  reserve=", vm.toString(r.reserveId), "  price=", vm.toString(r.price), "  (exact match)"));
        }

        // Scope completeness: nothing below the target may remain reachable from a repointed reserve.
        console.log(string.concat("  legs rebuilt: ", vm.toString(rebuiltKeys.length), "  adapters+legs repointed: ", vm.toString(results.length)));
    }

    // ------------------------------------------------------------------ dress rehearsal

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

        _proveBoundsMoved();

        vm.revertToState(snap);

        for (uint256 i; i < results.length; i++) {
            require(
                IAaveOracleLike(AAVE_ORACLE).getReserveSource(results[i].reserveId) == results[i].replaces,
                string.concat(results[i].symbol, ": rehearsal state did not roll back")
            );
        }
        console.log(string.concat("  ", vm.toString(checked), " repoints executed as the Owner Safe, verified, and rolled back"));
    }

    /// @dev Non-vacuity for the bound change itself, per rebuilt leg rather than per reserve, because
    ///      the legs are what carry the bound.
    ///
    ///      For each replaced leg: warp to just past its OLD bound, measured from that leg's own
    ///      data timestamp, and assert the OLD leg reverts while the NEW leg still prices. Then warp
    ///      to just past the NEW bound and assert the new leg reverts too.
    ///
    ///      Measuring from the leg's own `updatedAt` matters: every feed type here compares
    ///      `block.timestamp > updatedAt + bound`, so warping a fixed offset from `now` overshoots by
    ///      however stale each source already is and produces spurious failures on the
    ///      exactly-at-the-bound case.
    function _proveBoundsMoved() internal {
        uint256 t = forkTimestamp;
        require(t > 0, "fork timestamp was never captured");
        require(rebuiltKeys.length > 0, "no legs were rebuilt - the proof would be vacuous");

        uint256 proven;
        for (uint256 i; i < rebuiltKeys.length; i++) {
            vm.warp(t);
            address oldLeg = rebuiltKeys[i];
            address newLeg = rebuilt[oldLeg];
            uint256 oldBound = ChainlinkPriceFeed(oldLeg).rateMaxStaleness();
            uint256 updatedAt = _legUpdatedAt(oldLeg);
            if (updatedAt == 0) continue;                 // no readable timestamp, covered by price equality only
            if (updatedAt + oldBound <= t) continue;      // already stale on this fork; control would be vacuous

            // Just past the OLD bound: old must revert, new must still price.
            vm.warp(updatedAt + oldBound + 1);
            require(_reverts(oldLeg), string.concat(ChainlinkPriceFeed(oldLeg).description(), ": OLD leg does not fail past its own bound - the bound was not binding"));
            require(!_reverts(newLeg), string.concat(ChainlinkPriceFeed(oldLeg).description(), ": NEW leg fails inside the widened window - the change bought nothing"));

            // Exactly at the new bound: still prices. One second past: fails closed.
            vm.warp(updatedAt + TARGET);
            require(!_reverts(newLeg), string.concat(ChainlinkPriceFeed(oldLeg).description(), ": NEW leg reverts exactly AT the target, off by one"));
            vm.warp(updatedAt + TARGET + 1);
            require(_reverts(newLeg), string.concat(ChainlinkPriceFeed(oldLeg).description(), ": NEW leg still prices past 7d - the bound is not enforced"));
            proven++;
        }

        vm.warp(t);
        require(proven > 0, "no leg produced a usable boundary proof - the whole check was vacuous");
        console.log(string.concat("  bound proven on ", vm.toString(proven), " of ", vm.toString(rebuiltKeys.length),
            " legs: old reverts past its bound, new prices there, new reverts at 7d+1s"));
    }

    /// @dev The data timestamp a leg's whole chain bounds against: the OLDEST timestamp reachable
    ///      from it. A composing leg (our sink feeds carry an underlying USD leg) enforces its own
    ///      bound AND its underlying's, so the chain fails closed as soon as the oldest of them
    ///      breaches. Using only the leg's own timestamp overstates the surviving window and makes
    ///      the exactly-at-the-bound assertion fail for the wrong reason. Returns 0 when unreadable.
    function _legUpdatedAt(address leg) internal view returns (uint256) {
        uint256 own = _ownUpdatedAt(leg);
        if (own == 0) return 0;

        (bool ok, bytes memory ret) = leg.staticcall(abi.encodeWithSignature("underlyingUsdFeed()"));
        if (ok && ret.length == 32) {
            address under = abi.decode(ret, (address));
            if (under != address(0)) {
                uint256 u = _legUpdatedAt(under);
                if (u == 0) return 0;              // cannot bound the chain, skip rather than guess
                if (u < own) return u;             // the underlying is older, so it binds first
            }
        }
        return own;
    }

    /// @dev The timestamp this leg itself compares against, per feed type.
    function _ownUpdatedAt(address leg) internal view returns (uint256) {
        (bool ok, bytes memory ret) = leg.staticcall(abi.encodeWithSignature("accountant()"));
        if (ok && ret.length == 32) {
            IVedaAccountant acct = IVedaAccountant(abi.decode(ret, (address)));
            return acct.accountantState().lastUpdateTimestamp;
        }
        (ok, ret) = leg.staticcall(abi.encodeWithSignature("sink()"));
        if (ok && ret.length == 32) {
            IOracleSink sink = IOracleSink(abi.decode(ret, (address)));
            (,,, uint256 updatedAt,) = sink.latestRoundData(OracleSinkPriceFeed(leg).token());
            return updatedAt;
        }
        (ok, ret) = leg.staticcall(abi.encodeWithSignature("rateFeed()"));
        if (ok && ret.length == 32) {
            IAggregatorV3 agg = IAggregatorV3(abi.decode(ret, (address)));
            (,,, uint256 updatedAt,) = agg.latestRoundData();
            return updatedAt;
        }
        return 0;
    }

    function _reverts(address source) internal view returns (bool) {
        (bool ok,) = source.staticcall(abi.encodeCall(ICLSynchronicityPriceAdapter.latestAnswer, ()));
        return !ok;
    }

    /**
     * @notice Field-by-field check that every repointed reserve reads a source whose whole leg graph
     *         is at or above the 7-day floor, with cap parameters intact. Shared by the rehearsal and
     *         runnable standalone AFTER the Owner Safe executes:
     *
     *           source .env && FOUNDRY_PROFILE=aave-deploy forge script \
     *             scripts/aave-v4/RaiseAllStalenessBoundsTo7d.s.sol:RaiseAllStalenessBoundsTo7d \
     *             --sig 'verifyLive()' --rpc-url $OPTIMISM_RPC -v
     *
     * @dev Asserts PROPERTIES, never deployed addresses, and walks the live graph rather than a
     *      hardcoded list — so a leg left behind below 7d is caught even if it was never in scope.
     *      Returns a count so a zero-iteration pass cannot read as success.
     */
    function verifyLive() public view returns (uint256 checked) {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        uint256[20] memory ids = [
            R_USDC, R_WETH, R_USDT, R_EURC, R_FRXUSD, R_WEETH, R_EBTC, R_EUSD, R_ETHFI, R_SETHFI,
            R_OP, R_WHYPE, R_BEHYPE, R_LIQUID_ETH, R_LIQUID_BTC, R_LIQUID_USD,
            R_IWSPYX, R_IPAXG, R_IWQQQX, R_IWTBLLX
        ];
        for (uint256 i; i < ids.length; i++) {
            address src = IAaveOracleLike(AAVE_ORACLE).getReserveSource(ids[i]);
            require(src.code.length != 0, "live source has no code");
            require(ICLSynchronicityPriceAdapter(src).decimals() == USD_FEED_DECIMALS, "live source decimals != 8");
            require(IAaveOracleLike(AAVE_ORACLE).getReservePrice(ids[i]) > 0, "live reserve price is not positive");
            _assertGraphAtLeastFloor(src, 0);
            checked++;
        }
        require(TARGET >= REQUIRED_FLOOR, "TARGET is below the reviewed floor - this run would lower a bound");
        console.log(string.concat("  verified ", vm.toString(checked), " reserves: every bounded leg in every graph is >= ", vm.toString(REQUIRED_FLOOR), "s"));
    }

    /// @dev Recursively assert every bounded leg reachable from `node` is at or above REQUIRED_FLOOR.
    ///      A cap adapter contributes no bound of its own; it just forwards to its legs.
    function _assertGraphAtLeastFloor(address node, uint256 depth) internal view {
        require(depth < 5, "leg graph deeper than expected");

        (bool hasBase, bytes memory baseRet) = node.staticcall(abi.encodeWithSignature("BASE_TO_USD_AGGREGATOR()"));
        (bool hasRatio, bytes memory ratioRet) = node.staticcall(abi.encodeWithSignature("RATIO_PROVIDER()"));
        (bool hasAsset, bytes memory assetRet) = node.staticcall(abi.encodeWithSignature("ASSET_TO_USD_AGGREGATOR()"));

        bool isAdapter;
        if (hasBase && baseRet.length == 32) { isAdapter = true; _assertGraphAtLeastFloor(abi.decode(baseRet, (address)), depth + 1); }
        if (hasRatio && ratioRet.length == 32) { isAdapter = true; _assertGraphAtLeastFloor(abi.decode(ratioRet, (address)), depth + 1); }
        if (hasAsset && assetRet.length == 32) { isAdapter = true; _assertGraphAtLeastFloor(abi.decode(assetRet, (address)), depth + 1); }
        if (isAdapter) return;

        (bool hasBound, bytes memory boundRet) = node.staticcall(abi.encodeWithSignature("rateMaxStaleness()"));
        if (hasBound && boundRet.length == 32) {
            uint256 bound = abi.decode(boundRet, (uint256));
            require(bound >= REQUIRED_FLOOR, string.concat("leg below the 7d floor: ", vm.toString(node), " bound=", vm.toString(bound)));
            (bool hasUnder, bytes memory underRet) = node.staticcall(abi.encodeWithSignature("underlyingUsdFeed()"));
            if (hasUnder && underRet.length == 32) {
                address under = abi.decode(underRet, (address));
                if (under != address(0)) _assertGraphAtLeastFloor(under, depth + 1);
            }
        }
        // else: a raw aggregator or a constant adapter, which carries no bound of its own.
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
            console.log("    calldata", vm.toString(abi.encodeCall(ISpokeConfiguratorLike.updateReservePriceSource, (SPOKE, r.reserveId, r.newSource))));
        }
    }

    /// @dev ONLY THE FILE FROM A --broadcast RUN IS SUBMITTABLE. A dry run deploys into a simulated
    ///      EVM, so the addresses it writes do not exist on chain.
    function _writeSafeBatchJson() internal {
        string memory json = string.concat(
            '{\n  "chainId": "10",\n  "safeAddress": "', vm.toString(OWNER_SAFE), '",\n', '  "meta": {\n    "txBuilderVersion": "1.16.5"\n  },\n  "transactions": [\n'
        );
        for (uint256 i; i < results.length; i++) {
            json = string.concat(
                json,
                '    {\n      "to": "', vm.toString(SPOKE_CONFIGURATOR),
                '",\n      "value": "0",\n      "data": "',
                vm.toString(abi.encodeCall(ISpokeConfiguratorLike.updateReservePriceSource, (SPOKE, results[i].reserveId, results[i].newSource))),
                '"\n    }',
                i + 1 == results.length ? "\n" : ",\n"
            );
        }
        json = string.concat(json, "  ]\n}\n");
        vm.writeFile("output/3CP-657-RaiseAllStaleness7d-10.json", json);
        console.log("");
        console.log("wrote output/3CP-657-RaiseAllStaleness7d-10.json  (drop-in for 3CP-Secure queued/657/optimism.json)");
        console.log("  !! only submit this file if it came from a --broadcast run !!");
    }

    function _writeJson() internal {
        string memory json = "{";
        json = string.concat(json, '"aclManager":"', vm.toString(ACCESS_MANAGER), '","targetStaleness":"', vm.toString(TARGET), '"');
        for (uint256 i; i < results.length; i++) {
            json = string.concat(
                json, ',"', results[i].symbol, '":{"reserveId":"', vm.toString(results[i].reserveId),
                '","source":"', vm.toString(results[i].newSource),
                '","replaces":"', vm.toString(results[i].replaces),
                '","price":"', vm.toString(results[i].price), '"}'
            );
        }
        json = string.concat(json, ',"legs":{');
        for (uint256 i; i < rebuiltKeys.length; i++) {
            json = string.concat(json, i == 0 ? "" : ",", '"', vm.toString(rebuiltKeys[i]), '":"', vm.toString(rebuilt[rebuiltKeys[i]]), '"');
        }
        json = string.concat(json, "}}");
        vm.writeFile("output/AllStaleness7dFeedsOP.json", json);
        console.log("wrote output/AllStaleness7dFeedsOP.json");
    }
}
