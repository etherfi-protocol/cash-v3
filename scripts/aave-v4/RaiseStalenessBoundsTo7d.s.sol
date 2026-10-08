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
 * @title RaiseStalenessBoundsTo7d
 * @notice 3CP-657. Raises price-feed staleness bounds on the prod Summer Lend (Aave v4) instance on
 *         OP Mainnet to a 7-day floor, and rebuilds every cap adapter that bakes a changed leg in
 *         immutably.
 *
 *         TWO PHASES, DELIBERATELY SEPARATE ENTRYPOINTS.
 *
 *           `runKeeperPhase()` — the 6 Veda accountant RATE legs and the 6 adapters above them.
 *                                12 contracts, 6 reserves (6, 7, 9, 13, 14, 15).
 *           `runAllPhase()`    — everything: 25 legs, 12 adapters, 37 contracts, 20 reserves.
 *
 *         The phases exist because the two clock families have opposite risk profiles and only one
 *         of them has an observed problem. Keeper legs are monotone accruals drifting <1.5 bps/day
 *         whose publisher genuinely stalls for days (eBTC 624.04h worst gap, liquidETH 96.76h, six
 *         breaches of the current 48h bound). Widening those costs single-digit bps and fixes real
 *         outages. Market legs have NEVER breached even their current bound (max observed gap 0.34h
 *         on ETH/USD and BTC/USD against 48h), so widening them fixes nothing measurable and instead
 *         extends how long a DEAD feed keeps serving a stale price:
 *
 *           feed          worst adverse move at 48h -> at 7d   (delta)
 *           ETHFI / USD        28.48%  ->  54.84%   (+26.36pp)
 *           HYPE  / USD        27.79%  ->  34.28%    (+6.49pp)
 *           ETH   / USD        23.48%  ->  26.24%    (+2.76pp)
 *           OP    / USD        19.03%  ->  19.74%    (+0.71pp)
 *           BTC   / USD        13.73%  ->  16.71%    (+2.98pp)
 *
 *         Against bad-debt tolerance `1 - 1/(1+bonus)` from the LT trigger: 13.04% on
 *         liquidETH/liquidBTC (CF 70%, bonus 1.150x), 6.98% on liquidUSD/eUSD (CF 90%, 1.075x),
 *         16.67% on sETHFI (CF 40%, 1.200x). Only reserves 0 (USDC) and 1 (WETH) are borrowable, so
 *         the loss path is a stale-high collateral price funding an over-borrow, capped by drawable
 *         liquidity (~$20.8M at the time of writing) — real and reachable, not hypothetical.
 *
 *         So `runAllPhase()` is an explicit ECONOMIC RISK ACCEPTANCE, not a semantics-preserving
 *         liveness fix, and its compensating control (off-chain feed monitoring with a dead-feed
 *         detection latency well inside 7 days) lives entirely OUTSIDE this repository. Run it only
 *         with that sign-off recorded. `runKeeperPhase()` carries no such objection.
 *
 *         WHY A REDEPLOY AND NOT A SETTER. `rateMaxStaleness` is immutable on all three of our feed
 *         types, and Aave's cap adapters hold their legs immutable with the cap setters permanently
 *         unreachable on this instance (the ACL manager is the AccessManager, which implements
 *         neither `isRiskAdmin` nor `isPoolAdmin`). A new bound needs a new leg, and a new leg needs
 *         a rebuild of every adapter sitting on it.
 *
 *         NOTHING BUT THE BOUND CHANGES. Every new leg wraps the same aggregator / accountant /
 *         sink+token as the leg it replaces, carries its description across verbatim, and keeps
 *         `isStableToken` and the rate precision identical. Every rebuilt adapter reuses the same
 *         siblings and carries the same cap parameters forward, read off the live adapter AND
 *         asserted equal to the reviewed constants below. Shared legs are deployed once and reused,
 *         so the pre-change sharing graph is preserved exactly.
 *
 *         FAIL-CLOSED ON CONFIG DRIFT. Before deploying anything, `_assertPreState` requires every
 *         one of the 23 reserves to still read the exact source recorded at review time, and every
 *         adapter to still carry the exact cap parameters recorded at review time. Two oracle graphs
 *         can return the same spot price while being semantically different, so price equality alone
 *         is not enough to prove nothing moved. If another governance action repointed a reserve or
 *         re-snapshotted a cap since this was authored, the run aborts and the change needs a fresh
 *         review rather than silently overwriting the newer configuration.
 *
 * Usage — dry run first (no --broadcast), which still runs every assertion:
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RaiseStalenessBoundsTo7d.s.sol:RaiseStalenessBoundsTo7d \
 *     --sig 'runKeeperPhase()' --rpc-url $OPTIMISM_RPC \
 *     --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e -vvv
 *
 * Broadcast (swap --sig for runAllPhase() only with the risk sign-off recorded):
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RaiseStalenessBoundsTo7d.s.sol:RaiseStalenessBoundsTo7d \
 *     --sig 'runKeeperPhase()' --rpc-url $OPTIMISM_RPC --account etherfi-deployer \
 *     --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 *
 * Post-execution, matching the phase you ran:
 *   --sig 'verifyKeeperPhase()'   or   --sig 'verifyAllPhase()'
 */
contract RaiseStalenessBoundsTo7d is Script {
    // ---------------------------------------------------------------- instance (OP Mainnet)
    address constant ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
    address constant SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    address constant OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

    /// @notice The bound every in-scope leg is set to.
    uint256 constant TARGET = 7 days;

    /// @dev The floor the post-state check asserts, deliberately a SEPARATE literal from `TARGET`.
    ///      If the check reused `TARGET`, lowering `TARGET` would move the setter and the assertion
    ///      together and the check would pass tautologically — verified: `TARGET = 5 days` once
    ///      produced a fully green run. Pinning the reviewed floor independently means a change to
    ///      the deployed bound has to be reflected here on purpose.
    uint256 constant REQUIRED_FLOOR = 604800; // 7 days, the value this change was reviewed at

    uint8 constant USD_FEED_DECIMALS = 8;

    /// @dev Aave's `PriceCapAdapterBase` rejects `snapshotTimestamp < block.timestamp - term`, so a
    ///      snapshot EXACTLY `term` old is still valid. The guard below therefore uses `>=`, matching
    ///      `PriceCapAdapterBase._setCapParameters` rather than being one second stricter than it.
    uint48 constant MAX_SNAPSHOT_TERM = 180 days;

    uint256 constant RESERVE_COUNT = 23;

    // ---------------------------------------------------------------- live legs below 7d
    address constant L_ETHFI_USD      = 0x53c3d3c36cae804E6B639cA2600662aF51B4fFc9; // 36h
    address constant L_HYPE_USD       = 0xB41cE833937aEf200B77fa796bADED2F6Bea7D82; // 36h
    address constant L_OP_USD         = 0x3b79488486f0aD5F05a66Ad377E25b829fff2bD5; // 36h
    address constant L_BTC_USD        = 0x7F5276E01c62490C67490BB6515Ed075F813Ac50; // 48h
    address constant L_ETH_USD_WETH   = 0xCFe45EF2B9E138E5A2e1C25592441D5c556B3ca3; // 48h, reserve 1
    address constant L_ETH_USD_SHARED = 0x62B6153a877b0Eb64A94F132b04D3Afb018c0d16; // 48h, 5 + 13
    address constant L_EURC_USD       = 0x1fF6e0FBd92038BDD7dA83A62A45C5E1D036A237; // 48h
    address constant L_USDC_USD       = 0xADfA1a2BC18d76176735ac8E3277A351663fa19B; // 48h, 0 + 15
    address constant L_USDT_USD       = 0xfd503fdB6d37bC1e864b4B58f787F0A3F704402c; // 48h
    address constant L_FRXUSD_USD     = 0xe6e0fe0C3Ac45d1FE71AF7853007467eE89e1e67; // 48h
    address constant L_BEHYPE_RATE    = 0xcd0D452cDbaD335a7423299dC0EE0f544e5FfD96; // 48h, 18 dec
    address constant L_WEETH_RATE     = 0xA9E4936d025eB904a767f6F0c16f38c5C2016711; // 48h, 18 dec
    address constant L_PAXG_USD       = 0x7DC0EAff1ECaED8A8A5aDC07dEe1997fF4617800; // 72h
    address constant L_QQQ_USD        = 0x459E1D5e587eB81bA25C6AA1e817e40bd36fb2F4; // 72h
    address constant L_SPY_USD        = 0x045ACc54e73f93c5b9B4F20Fa01931cB23234C38; // 72h
    address constant L_TBLL_USD       = 0x1A74F66b6CF21b582C316398925b24D3D04C8C7D; // 72h

    address constant V_EBTC_RATE       = 0xAd6ad4a8647c60C17E0B4eA9f78e8b663EC35599; // 48h Veda
    address constant V_EUSD_RATE       = 0x311486d71761Caf9d68f6F03bf1d8c05c01bB863; // 48h Veda
    address constant V_LIQUID_BTC_RATE = 0x60BE06699ABe614E0FbA99eC11a1CDa6B2238755; // 48h Veda
    address constant V_LIQUID_ETH_RATE = 0x1305D82Ce705b4E73bF22E5548c6cF90bA1735Db; // 48h Veda
    address constant V_LIQUID_USD_RATE = 0x0C5631727ECF13f3e726Bc3301E364Af51b69295; // 48h Veda
    address constant V_SETHFI_RATE     = 0xb1F53B6aA18205bb8E468EC6a8cF3b8194ed5d7E; // 48h Veda

    address constant S_IWSPYX  = 0x253F4Fb7082e314430972A2B783aD7514D20d64c; // 72h sink feed
    address constant S_IWQQQX  = 0xb5f61BDfCa60c02d13377d4386288FE143b9d6bE; // 72h sink feed
    address constant S_IWTBLLX = 0x1cee92F999D536320aFb740b2ea5318C45d9C93B; // 72h sink feed

    // ---------------------------------------------------------------- live adapters
    address constant A_USDC       = 0xE55eacdC1EC9dA0f33B9CEa7D136a47CC6008C69; // stable
    address constant A_USDT       = 0x6a6B2529c1BC14f0A062D7903B4894B477BfFc92; // stable
    address constant A_FRXUSD     = 0x859c126dad6952a798ecdc5c06f7063B8a9FCC31; // stable
    address constant A_EURC       = 0xC1Cf424A5d58BB943aDbA7fF3E1E1D2e354C2CD1; // EUR stable
    address constant A_WEETH      = 0x81ED135fc10FF855202E582d8cfd50E8A5533fd9; // CLRate
    address constant A_EBTC       = 0xFa80bA4b7aC946F3b45DC8ED537b1BEbD8eC860f; // CLRate
    address constant A_EUSD       = 0xD617E1D59aA992D985c07ADC48c36aD2a00E751b; // CLRate
    address constant A_SETHFI     = 0xd452ca984E0606297bCb430e076087F126e24a38; // CLRate
    address constant A_BEHYPE     = 0xc6d0023679769A532879AE50E57F40aB628201E7; // CLRate
    address constant A_LIQUID_ETH = 0x48420d702a3190235B5A5D123ca82f876752add1; // CLRate
    address constant A_LIQUID_BTC = 0xD60ec8fCba09c7642099eA89A9D58721B00277C7; // CLRate
    address constant A_LIQUID_USD = 0x17DdE04d8Ff1024D3076944658ED9B6bd5F51451; // CLRate

    // Reserves already at or above the floor throughout; never touched, but their sources are still
    // pinned so a repoint of one of them aborts the run.
    address constant A_LIQUID_RESERVE = 0x6b5C6155A07A5E3af6591d48571FC1BdFEc929BC; // reserve 16
    address constant A_WEEUR          = 0xFA239571dDa672A935Fb7962513b37b1CfF280cb; // reserve 17
    address constant A_LIQUID_RWA     = 0x6Bf29C9bec671EE7787352EBc42c2151a7BC2854; // reserve 18

    // ---------------------------------------------------------------- reviewed cap parameters
    // Read off the live adapters at OP block 155832548 and pinned. `_assertPreState` requires the
    // live values to still equal these BEFORE anything is deployed, and the post-execution verifier
    // requires the rebuilt adapters to carry them. A re-snapshot between review and execution
    // therefore aborts rather than being silently carried into new adapters.
    uint48 constant SNAP_TS_CAPO   = 1780627963; // every adapter except beHYPE
    uint48 constant SNAP_TS_BEHYPE = 1785344431;

    uint104 constant SNAP_WEETH      = 1_095_883_047_457_899_600;
    uint104 constant SNAP_EBTC       = 1_003_626_440_000_000_000;
    uint104 constant SNAP_EUSD       = 1_065_594_833_004_492_070;
    uint104 constant SNAP_SETHFI     = 1_187_971_295_403_462_986;
    uint104 constant SNAP_BEHYPE     = 1_018_457_451_127_239_140;
    uint104 constant SNAP_LIQUID_ETH = 1_094_734_190_917_310_748;
    uint104 constant SNAP_LIQUID_BTC = 1_029_351_010_000_000_000;
    uint104 constant SNAP_LIQUID_USD = 1_160_589_000_000_000_000;

    uint16 constant GROWTH_WEETH      = 500;  //  5.00%
    uint16 constant GROWTH_EBTC       = 100;  //  1.00%
    uint16 constant GROWTH_EUSD       = 75;   //  0.75%
    uint16 constant GROWTH_SETHFI     = 1200; // 12.00%
    uint16 constant GROWTH_BEHYPE     = 300;  //  3.00%
    uint16 constant GROWTH_LIQUID_ETH = 500;  //  5.00%
    uint16 constant GROWTH_LIQUID_BTC = 300;  //  3.00%
    uint16 constant GROWTH_LIQUID_USD = 750;  //  7.50%

    int256 constant PAR_CAP      = 1.04e8; // USDC, USDT, frxUSD
    int256 constant EURC_CAP_RATIO = 1.04e8;
    uint8  constant EURC_RATIO_DECIMALS = 8;
    uint8  constant VEDA_RATE_DECIMALS = 18;

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
    uint256 constant R_LIQUID_RESERVE = 16;
    uint256 constant R_WEEUR = 17;
    uint256 constant R_LIQUID_RWA = 18;
    uint256 constant R_IWSPYX = 19;
    uint256 constant R_IPAXG = 20;
    uint256 constant R_IWQQQX = 21;
    uint256 constant R_IWTBLLX = 22;

    enum CapKind { None, Growth, Stable, EurStable }

    struct Expect {
        uint256 reserveId;
        string symbol;
        address source;     // the source recorded at review time
        CapKind kind;
        uint104 snapRatio;
        uint48 snapTs;
        uint16 growth;
        int256 cap;         // par cap / EUR cap ratio
    }

    struct Result {
        string symbol;
        uint256 reserveId;
        address newSource;
        address replaces;
        uint256 price;
    }

    Result[] internal results;

    /// @dev old leg -> new leg, so a leg shared by two reserves is deployed exactly once.
    mapping(address => address) internal rebuilt;
    address[] internal rebuiltKeys;

    /// @dev true when only the Veda keeper legs are in scope.
    bool internal keeperOnly;

    /// @dev Captured before anything warps the clock. See `_proveBoundsMoved`.
    uint256 internal forkTimestamp;

    // ---------------------------------------------------------------- reviewed pre-state

    /// @dev Every reserve on the instance and the exact source it read at review time. All 23 are
    ///      listed, including the three this change never touches, because a repoint of ANY of them
    ///      means the instance moved under the plan.
    function _expectations() internal pure returns (Expect[RESERVE_COUNT] memory e) {
        e[0]  = Expect(R_USDC,            "USDC",          A_USDC,            CapKind.Stable,    0, 0, 0, PAR_CAP);
        e[1]  = Expect(R_WETH,            "WETH",          L_ETH_USD_WETH,    CapKind.None,      0, 0, 0, 0);
        e[2]  = Expect(R_USDT,            "USDT",          A_USDT,            CapKind.Stable,    0, 0, 0, PAR_CAP);
        e[3]  = Expect(R_EURC,            "EURC",          A_EURC,            CapKind.EurStable, 0, 0, 0, EURC_CAP_RATIO);
        e[4]  = Expect(R_FRXUSD,          "frxUSD",        A_FRXUSD,          CapKind.Stable,    0, 0, 0, PAR_CAP);
        e[5]  = Expect(R_WEETH,           "weETH",         A_WEETH,           CapKind.Growth,    SNAP_WEETH,      SNAP_TS_CAPO,   GROWTH_WEETH, 0);
        e[6]  = Expect(R_EBTC,            "eBTC",          A_EBTC,            CapKind.Growth,    SNAP_EBTC,       SNAP_TS_CAPO,   GROWTH_EBTC, 0);
        e[7]  = Expect(R_EUSD,            "eUSD",          A_EUSD,            CapKind.Growth,    SNAP_EUSD,       SNAP_TS_CAPO,   GROWTH_EUSD, 0);
        e[8]  = Expect(R_ETHFI,           "ETHFI",         L_ETHFI_USD,       CapKind.None,      0, 0, 0, 0);
        e[9]  = Expect(R_SETHFI,          "sETHFI",        A_SETHFI,          CapKind.Growth,    SNAP_SETHFI,     SNAP_TS_CAPO,   GROWTH_SETHFI, 0);
        e[10] = Expect(R_OP,              "OP",            L_OP_USD,          CapKind.None,      0, 0, 0, 0);
        e[11] = Expect(R_WHYPE,           "wHYPE",         L_HYPE_USD,        CapKind.None,      0, 0, 0, 0);
        e[12] = Expect(R_BEHYPE,          "beHYPE",        A_BEHYPE,          CapKind.Growth,    SNAP_BEHYPE,     SNAP_TS_BEHYPE, GROWTH_BEHYPE, 0);
        e[13] = Expect(R_LIQUID_ETH,      "liquidETH",     A_LIQUID_ETH,      CapKind.Growth,    SNAP_LIQUID_ETH, SNAP_TS_CAPO,   GROWTH_LIQUID_ETH, 0);
        e[14] = Expect(R_LIQUID_BTC,      "liquidBTC",     A_LIQUID_BTC,      CapKind.Growth,    SNAP_LIQUID_BTC, SNAP_TS_CAPO,   GROWTH_LIQUID_BTC, 0);
        e[15] = Expect(R_LIQUID_USD,      "liquidUSD",     A_LIQUID_USD,      CapKind.Growth,    SNAP_LIQUID_USD, SNAP_TS_CAPO,   GROWTH_LIQUID_USD, 0);
        e[16] = Expect(R_LIQUID_RESERVE,  "liquidRESERVE", A_LIQUID_RESERVE,  CapKind.Growth,    0, 0, 0, 0); // untouched
        e[17] = Expect(R_WEEUR,           "weEUR",         A_WEEUR,           CapKind.Growth,    0, 0, 0, 0); // untouched
        e[18] = Expect(R_LIQUID_RWA,      "liquidRWA",     A_LIQUID_RWA,      CapKind.Growth,    0, 0, 0, 0); // untouched
        e[19] = Expect(R_IWSPYX,          "iwSPYx",        S_IWSPYX,          CapKind.None,      0, 0, 0, 0);
        e[20] = Expect(R_IPAXG,           "iPAXG",         L_PAXG_USD,        CapKind.None,      0, 0, 0, 0);
        e[21] = Expect(R_IWQQQX,          "iwQQQx",        S_IWQQQX,          CapKind.None,      0, 0, 0, 0);
        e[22] = Expect(R_IWTBLLX,         "iwTBLLx",       S_IWTBLLX,         CapKind.None,      0, 0, 0, 0);
    }

    /// @dev Which reserves are untouched, so the pre-state check knows not to expect a cap assertion
    ///      against pinned values it has no reviewed numbers for.
    function _isUntouched(uint256 reserveId) internal pure returns (bool) {
        return reserveId == R_LIQUID_RESERVE || reserveId == R_WEEUR || reserveId == R_LIQUID_RWA;
    }

    // ---------------------------------------------------------------- entrypoints

    function runKeeperPhase() public {
        keeperOnly = true;
        _run();
    }

    function runAllPhase() public {
        keeperOnly = false;
        _run();
    }

    function _run() internal {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        require(ACCESS_MANAGER.code.length != 0, "no code at the AccessManager");
        forkTimestamp = block.timestamp;

        // Fail closed BEFORE spending gas if the instance moved under the plan.
        _assertPreState();

        vm.startBroadcast();

        // ---- Veda keeper rate legs, always in scope
        _vedaLeg(V_EBTC_RATE);
        _vedaLeg(V_EUSD_RATE);
        _vedaLeg(V_LIQUID_BTC_RATE);
        _vedaLeg(V_LIQUID_ETH_RATE);
        _vedaLeg(V_LIQUID_USD_RATE);
        _vedaLeg(V_SETHFI_RATE);

        if (!keeperOnly) {
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
            // Sink feeds compose an underlying USD leg, so their underlying must exist first.
            _sinkLeg(S_IWSPYX, L_SPY_USD);
            _sinkLeg(S_IWQQQX, L_QQQ_USD);
            _sinkLeg(S_IWTBLLX, L_TBLL_USD);
        }

        // ---- adapters above a changed Veda leg, always in scope
        _record("eBTC", _rebuildGrowth(A_EBTC, "eBTC"), R_EBTC);
        _record("eUSD", _rebuildGrowth(A_EUSD, "eUSD"), R_EUSD);
        _record("sETHFI", _rebuildGrowth(A_SETHFI, "sETHFI"), R_SETHFI);
        _record("liquidETH", _rebuildGrowth(A_LIQUID_ETH, "liquidETH"), R_LIQUID_ETH);
        _record("liquidBTC", _rebuildGrowth(A_LIQUID_BTC, "liquidBTC"), R_LIQUID_BTC);
        _record("liquidUSD", _rebuildGrowth(A_LIQUID_USD, "liquidUSD"), R_LIQUID_USD);

        if (!keeperOnly) {
            _record("WETH", _at(L_ETH_USD_WETH), R_WETH);
            _record("ETHFI", _at(L_ETHFI_USD), R_ETHFI);
            _record("OP", _at(L_OP_USD), R_OP);
            _record("wHYPE", _at(L_HYPE_USD), R_WHYPE);
            _record("iPAXG", _at(L_PAXG_USD), R_IPAXG);
            _record("iwSPYx", _at(S_IWSPYX), R_IWSPYX);
            _record("iwQQQx", _at(S_IWQQQX), R_IWQQQX);
            _record("iwTBLLx", _at(S_IWTBLLX), R_IWTBLLX);
            _record("USDC", _rebuildStable(A_USDC, "USDC"), R_USDC);
            _record("USDT", _rebuildStable(A_USDT, "USDT"), R_USDT);
            _record("frxUSD", _rebuildStable(A_FRXUSD, "frxUSD"), R_FRXUSD);
            _record("EURC", _rebuildEurStable(A_EURC), R_EURC);
            _record("weETH", _rebuildGrowth(A_WEETH, "weETH"), R_WEETH);
            _record("beHYPE", _rebuildGrowth(A_BEHYPE, "beHYPE"), R_BEHYPE);
        }

        vm.stopBroadcast();

        uint256 expectedLegs = keeperOnly ? 6 : 25;
        uint256 expectedRepoints = keeperOnly ? 6 : 20;
        require(rebuiltKeys.length == expectedLegs, "leg count does not match the phase");
        require(results.length == expectedRepoints, "repoint count does not match the phase");

        _verify();
        _rehearse();
        _printSafeBatch();
        _writeSafeBatchJson();
        _writeJson();
    }

    // ---------------------------------------------------------------- pre-state gate

    /// @dev Requires the instance to be byte-identical, in every way this plan depends on, to what
    ///      was reviewed. Price equality cannot substitute for this: two semantically different
    ///      oracle graphs can return the same spot price, so a reserve repointed by another
    ///      governance action would sail through a price check while this run overwrote it with a
    ///      source built from stale constants.
    function _assertPreState() internal view {
        require(ISpokeLike(SPOKE).getReserveCount() == RESERVE_COUNT, "reserve count changed - a listing happened, re-review required");
        Expect[RESERVE_COUNT] memory expects = _expectations();

        for (uint256 i; i < expects.length; i++) {
            Expect memory e = expects[i];
            address live = IAaveOracleLike(AAVE_ORACLE).getReserveSource(e.reserveId);
            require(
                live == e.source,
                string.concat(e.symbol, ": reserve source drifted from the reviewed one - live=", vm.toString(live), " reviewed=", vm.toString(e.source), " - re-review required")
            );

            if (_isUntouched(e.reserveId)) continue;

            if (e.kind == CapKind.Growth) {
                IPriceCapAdapter cap = IPriceCapAdapter(e.source);
                require(cap.getSnapshotRatio() == e.snapRatio, string.concat(e.symbol, ": live snapshot ratio is not the reviewed value"));
                require(cap.getSnapshotTimestamp() == e.snapTs, string.concat(e.symbol, ": live snapshot timestamp is not the reviewed value"));
                require(cap.getMaxYearlyGrowthRatePercent() == e.growth, string.concat(e.symbol, ": live growth percent is not the reviewed value"));
                require(!cap.isCapped(), string.concat(e.symbol, ": live cap is already binding"));
            } else if (e.kind == CapKind.Stable) {
                require(IPriceCapAdapterStable(e.source).getPriceCap() == e.cap, string.concat(e.symbol, ": live par cap is not the reviewed value"));
                require(!IPriceCapAdapterStable(e.source).isCapped(), string.concat(e.symbol, ": live cap is already binding"));
            } else if (e.kind == CapKind.EurStable) {
                require(IEURPriceCapAdapterStable(e.source).getPriceCapRatio() == e.cap, string.concat(e.symbol, ": live EUR cap ratio is not the reviewed value"));
                require(IEURPriceCapAdapterStable(e.source).RATIO_DECIMALS() == EURC_RATIO_DECIMALS, string.concat(e.symbol, ": live EUR ratio decimals changed"));
            }
        }
        console.log(string.concat("  pre-state ok: all ", vm.toString(RESERVE_COUNT), " reserve sources and every reviewed cap parameter match the plan"));
    }

    // ---------------------------------------------------------------- leg builders

    function _at(address oldLeg) internal view returns (address a) {
        a = rebuilt[oldLeg];
        require(a != address(0), "leg was never rebuilt");
    }

    function _preLeg(address oldLeg, string memory what) internal view {
        require(rebuilt[oldLeg] == address(0), string.concat(what, ": leg already rebuilt in this run"));
        require(ChainlinkPriceFeed(oldLeg).rateMaxStaleness() < TARGET, string.concat(what, ": live bound is already at or above the target"));
        require(!ChainlinkPriceFeed(oldLeg).isStableToken(), string.concat(what, ": live leg snaps to $1, the replacement would not match"));
    }

    function _postLeg(address oldLeg, address newLeg, string memory what) internal {
        require(ChainlinkPriceFeed(newLeg).rateMaxStaleness() == TARGET, string.concat(what, ": bound did not take"));
        require(ChainlinkPriceFeed(newLeg).decimals() == ChainlinkPriceFeed(oldLeg).decimals(), string.concat(what, ": feed decimals changed"));
        int256 before = IAaveV4PriceFeed(oldLeg).latestAnswer();
        int256 now_ = IAaveV4PriceFeed(newLeg).latestAnswer();
        require(before > 0, string.concat(what, ": live leg returned a non-positive answer"));
        require(now_ == before, string.concat(what, ": rebuilt leg differs - live=", vm.toString(before), " new=", vm.toString(now_)));
        rebuilt[oldLeg] = newLeg;
        rebuiltKeys.push(oldLeg);
        console.log(string.concat("  leg ", what, "  ", vm.toString(newLeg), "  (was ", vm.toString(oldLeg), ")"));
    }

    function _chainlinkLeg(address oldLeg) internal {
        ChainlinkPriceFeed live = ChainlinkPriceFeed(oldLeg);
        string memory what = live.description();
        _preLeg(oldLeg, what);
        require(address(live.underlyingUsdFeed()) == address(0), string.concat(what, ": chainlink leg composes an underlying, unsupported by this run"));
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
        require(live.decimals() == VEDA_RATE_DECIMALS, string.concat(what, ": veda rate precision is not the reviewed one"));
        address newLeg = address(
            new VedaAccountantPriceFeed(live.accountant(), IAaveV4PriceFeed(address(0)), live.decimals(), TARGET, false, what)
        );
        require(address(VedaAccountantPriceFeed(newLeg).accountant()) == address(live.accountant()), string.concat(what, ": new leg reads a different accountant"));
        _postLeg(oldLeg, newLeg, what);
    }

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

    // ---------------------------------------------------------------- adapter rebuilds

    function _rebuildStable(address liveAdapter, string memory symbol) internal returns (address) {
        IPriceCapAdapterStable live = IPriceCapAdapterStable(liveAdapter);
        address newAsset = _at(address(live.ASSET_TO_USD_AGGREGATOR()));
        int256 cap = live.getPriceCap();
        require(cap == PAR_CAP, string.concat(symbol, ": live par cap is not the reviewed value"));

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

    function _rebuildEurStable(address liveAdapter) internal returns (address) {
        IEURPriceCapAdapterStable live = IEURPriceCapAdapterStable(liveAdapter);
        address liveBase = address(live.BASE_TO_USD_AGGREGATOR());
        require(rebuilt[liveBase] == address(0), "EURC: base leg was rebuilt, this path assumes it is reused untouched");
        require(ChainlinkPriceFeed(liveBase).rateMaxStaleness() >= REQUIRED_FLOOR, "EURC: base leg is below the floor and must be rebuilt");
        address newAsset = _at(address(live.ASSET_TO_USD_AGGREGATOR()));
        int256 capRatio = live.getPriceCapRatio();
        uint8 ratioDecimals = live.RATIO_DECIMALS();
        require(capRatio == EURC_CAP_RATIO, "EURC: live price cap ratio is not the reviewed value");
        require(ratioDecimals == EURC_RATIO_DECIMALS, "EURC: live ratio decimals are not the reviewed value");

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

        // Aave's `_setCapParameters` window. `>=` on the far edge, matching the adapter: it rejects
        // `snapshotTimestamp < block.timestamp - term`, so a snapshot exactly `term` old is valid.
        require(snapshotTs + minDelay <= block.timestamp, string.concat(symbol, ": carried snapshot is newer than MINIMUM_SNAPSHOT_DELAY"));
        require(snapshotTs + MAX_SNAPSHOT_TERM >= block.timestamp, string.concat(symbol, ": carried snapshot is older than 180 days, re-snapshot required"));
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

    // ---------------------------------------------------------------- verification

    function _verify() internal {
        console.log("");
        console.log("=== verification ===");
        for (uint256 i; i < results.length; i++) {
            Result storage r = results[i];
            require(r.reserveId < RESERVE_COUNT, string.concat(r.symbol, ": reserve id is not listed on the spoke"));

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
        console.log(string.concat("  phase=", keeperOnly ? "keeper" : "all", "  legs rebuilt: ", vm.toString(rebuiltKeys.length), "  reserves repointed: ", vm.toString(results.length)));
    }

    // ---------------------------------------------------------------- dress rehearsal

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

        uint256 checked = _verifyLive(keeperOnly);
        require(checked == RESERVE_COUNT, "rehearsal: post-state check did not cover every reserve");

        _proveBoundsMoved();

        vm.revertToState(snap);
        for (uint256 i; i < results.length; i++) {
            require(
                IAaveOracleLike(AAVE_ORACLE).getReserveSource(results[i].reserveId) == results[i].replaces,
                string.concat(results[i].symbol, ": rehearsal state did not roll back")
            );
        }
        console.log(string.concat("  ", vm.toString(results.length), " repoints executed as the Owner Safe, verified, and rolled back"));
    }

    /// @dev Non-vacuity for the bound change itself, per rebuilt leg. For each: warp to just past
    ///      that leg's OWN old bound and assert the old leg reverts while the new one still prices;
    ///      then assert the new leg prices at exactly the target and reverts one second later.
    ///
    ///      The boundary is measured from the leg's own data timestamp because every feed type here
    ///      compares `block.timestamp > updatedAt + bound`. Warping a fixed offset from `now`
    ///      overshoots by however stale each source already is.
    ///
    ///      A leg whose data is ALREADY past its old bound on this fork is still proven, by warping
    ///      backwards to the boundary rather than skipping it — skipping would weaken the proof in
    ///      exactly the late-feed scenario that motivates the change.
    function _proveBoundsMoved() internal {
        uint256 t = forkTimestamp;
        require(t > 0, "fork timestamp was never captured");
        require(rebuiltKeys.length > 0, "no legs were rebuilt - the proof would be vacuous");

        uint256 proven;
        for (uint256 i; i < rebuiltKeys.length; i++) {
            vm.warp(t);
            address oldLeg = rebuiltKeys[i];
            address newLeg = rebuilt[oldLeg];
            string memory what = ChainlinkPriceFeed(oldLeg).description();
            uint256 oldBound = ChainlinkPriceFeed(oldLeg).rateMaxStaleness();
            uint256 updatedAt = _legUpdatedAt(oldLeg);
            require(updatedAt > 0, string.concat(what, ": could not read a data timestamp, the boundary proof would be vacuous"));

            // Just past the OLD bound: old must revert, new must still price. Warping BACKWARDS is
            // fine and is required for a leg that is already stale at head.
            vm.warp(updatedAt + oldBound + 1);
            require(_reverts(oldLeg), string.concat(what, ": OLD leg does not fail past its own bound - the bound was not binding"));
            require(!_reverts(newLeg), string.concat(what, ": NEW leg fails inside the widened window - the change bought nothing"));

            vm.warp(updatedAt + TARGET);
            require(!_reverts(newLeg), string.concat(what, ": NEW leg reverts exactly AT the target, off by one"));
            vm.warp(updatedAt + TARGET + 1);
            require(_reverts(newLeg), string.concat(what, ": NEW leg still prices past the target - the bound is not enforced"));
            proven++;
        }

        vm.warp(t);
        require(proven == rebuiltKeys.length, "not every rebuilt leg produced a boundary proof");
        console.log(string.concat("  bound proven on ", vm.toString(proven), " of ", vm.toString(rebuiltKeys.length),
            " legs: old reverts past its bound, new prices there, new reverts at target+1s"));
    }

    /// @dev The data timestamp a leg's whole chain bounds against: the OLDEST reachable timestamp.
    ///      A composing leg (the sink feeds carry an underlying USD leg) enforces its own bound AND
    ///      its underlying's, so the chain fails closed as soon as the oldest breaches. Using only
    ///      the leg's own timestamp overstates the surviving window.
    function _legUpdatedAt(address leg) internal view returns (uint256) {
        uint256 own = _ownUpdatedAt(leg);
        if (own == 0) return 0;
        (bool ok, bytes memory ret) = leg.staticcall(abi.encodeWithSignature("underlyingUsdFeed()"));
        if (ok && ret.length == 32) {
            address under = abi.decode(ret, (address));
            if (under != address(0)) {
                uint256 u = _legUpdatedAt(under);
                if (u == 0) return 0;
                if (u < own) return u;
            }
        }
        return own;
    }

    function _ownUpdatedAt(address leg) internal view returns (uint256) {
        (bool ok, bytes memory ret) = leg.staticcall(abi.encodeWithSignature("accountant()"));
        if (ok && ret.length == 32) {
            return IVedaAccountant(abi.decode(ret, (address))).accountantState().lastUpdateTimestamp;
        }
        (ok, ret) = leg.staticcall(abi.encodeWithSignature("sink()"));
        if (ok && ret.length == 32) {
            (,,, uint256 updatedAt,) = IOracleSink(abi.decode(ret, (address))).latestRoundData(OracleSinkPriceFeed(leg).token());
            return updatedAt;
        }
        (ok, ret) = leg.staticcall(abi.encodeWithSignature("rateFeed()"));
        if (ok && ret.length == 32) {
            (,,, uint256 updatedAt,) = IAggregatorV3(abi.decode(ret, (address))).latestRoundData();
            return updatedAt;
        }
        return 0;
    }

    function _reverts(address source) internal view returns (bool) {
        (bool ok,) = source.staticcall(abi.encodeCall(ICLSynchronicityPriceAdapter.latestAnswer, ()));
        return !ok;
    }

    // ---------------------------------------------------------------- post-execution verifiers

    /// @notice Post-execution check for `runKeeperPhase()`.
    function verifyKeeperPhase() public view returns (uint256) { return _verifyLive(true); }

    /// @notice Post-execution check for `runAllPhase()`.
    function verifyAllPhase() public view returns (uint256) { return _verifyLive(false); }

    /**
     * @dev Walks EVERY reserve on the instance — `0 .. getReserveCount()-1`, not a hardcoded subset
     *      — and for each one asserts:
     *
     *        - it has code, prices positive, and reports 8 decimals;
     *        - its adapter TYPE and every reviewed immutable cap value are intact (snapshot ratio,
     *          snapshot timestamp, growth rate, par cap, EUR cap ratio and ratio decimals), so the
     *          standalone post-Safe run can prove the executed bundle preserved cap semantics rather
     *          than only that a price came back;
     *        - every bounded leg in its graph that is IN SCOPE for the phase is at or above
     *          `REQUIRED_FLOOR`.
     *
     *      Scope is phase-aware and that distinction is load-bearing: after the keeper phase the
     *      market legs are still legitimately at 36h/48h/72h, so asserting a global floor there
     *      would fail on a correct deployment. After the all phase every bounded leg must clear it.
     *
     *      Returns the number of reserves checked, which the caller compares against
     *      `getReserveCount()`, so a zero- or partial-iteration pass cannot read as success.
     */
    function _verifyLive(bool keeperScope) internal view returns (uint256 checked) {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        require(TARGET >= REQUIRED_FLOOR, "TARGET is below the reviewed floor - this run would lower a bound");

        uint256 count = ISpokeLike(SPOKE).getReserveCount();
        require(count == RESERVE_COUNT, "reserve count changed - re-review required");
        Expect[RESERVE_COUNT] memory expects = _expectations();

        for (uint256 i; i < count; i++) {
            Expect memory e = expects[i];
            require(e.reserveId == i, "expectation table is not indexed by reserve id");

            address src = IAaveOracleLike(AAVE_ORACLE).getReserveSource(i);
            require(src.code.length != 0, string.concat(e.symbol, ": live source has no code"));
            require(ICLSynchronicityPriceAdapter(src).decimals() == USD_FEED_DECIMALS, string.concat(e.symbol, ": live source decimals != 8"));
            require(IAaveOracleLike(AAVE_ORACLE).getReservePrice(i) > 0, string.concat(e.symbol, ": live reserve price is not positive"));

            // Reserves this change never touches must still read exactly their reviewed source.
            if (_isUntouched(i)) {
                require(src == e.source, string.concat(e.symbol, ": untouched reserve was repointed"));
            }

            // Cap semantics, asserted against the reviewed constants rather than re-read from the
            // contract under test, so a re-tune during execution is caught.
            if (!_isUntouched(i)) {
                if (e.kind == CapKind.Growth) {
                    IPriceCapAdapter cap = IPriceCapAdapter(src);
                    require(cap.getSnapshotRatio() == e.snapRatio, string.concat(e.symbol, ": snapshot ratio is not the reviewed value"));
                    require(cap.getSnapshotTimestamp() == e.snapTs, string.concat(e.symbol, ": snapshot timestamp is not the reviewed value"));
                    require(cap.getMaxYearlyGrowthRatePercent() == e.growth, string.concat(e.symbol, ": growth percent is not the reviewed value"));
                    require(cap.getMaxRatioGrowthPerSecondScaled() > 0, string.concat(e.symbol, ": growth floored to zero"));
                    require(cap.RATIO_DECIMALS() == VEDA_RATE_DECIMALS, string.concat(e.symbol, ": ratio decimals changed"));
                    require(!cap.isCapped(), string.concat(e.symbol, ": growth cap is binding, collateral is under-priced"));
                } else if (e.kind == CapKind.Stable) {
                    require(IPriceCapAdapterStable(src).getPriceCap() == e.cap, string.concat(e.symbol, ": par cap is not the reviewed value"));
                    require(!IPriceCapAdapterStable(src).isCapped(), string.concat(e.symbol, ": par cap is binding"));
                } else if (e.kind == CapKind.EurStable) {
                    require(IEURPriceCapAdapterStable(src).getPriceCapRatio() == e.cap, string.concat(e.symbol, ": EUR cap ratio is not the reviewed value"));
                    require(IEURPriceCapAdapterStable(src).RATIO_DECIMALS() == EURC_RATIO_DECIMALS, string.concat(e.symbol, ": EUR ratio decimals changed"));
                }
            }

            _assertGraphInScopeAtFloor(src, 0, keeperScope);
            checked++;
        }

        console.log(string.concat("  verified ", vm.toString(checked), " of ", vm.toString(count),
            " reserves | scope=", keeperScope ? "keeper legs" : "every bounded leg",
            " | floor=", vm.toString(REQUIRED_FLOOR), "s"));
    }

    /// @dev Recursively assert every bounded leg reachable from `node` that is in scope sits at or
    ///      above `REQUIRED_FLOOR`. A cap adapter contributes no bound of its own; it forwards to
    ///      its legs. In keeper scope only Veda legs are required to clear the floor.
    function _assertGraphInScopeAtFloor(address node, uint256 depth, bool keeperScope) internal view {
        require(depth < 5, "leg graph deeper than expected");

        (bool hasBase, bytes memory baseRet) = node.staticcall(abi.encodeWithSignature("BASE_TO_USD_AGGREGATOR()"));
        (bool hasRatio, bytes memory ratioRet) = node.staticcall(abi.encodeWithSignature("RATIO_PROVIDER()"));
        (bool hasAsset, bytes memory assetRet) = node.staticcall(abi.encodeWithSignature("ASSET_TO_USD_AGGREGATOR()"));

        bool isAdapter;
        if (hasBase && baseRet.length == 32) { isAdapter = true; _assertGraphInScopeAtFloor(abi.decode(baseRet, (address)), depth + 1, keeperScope); }
        if (hasRatio && ratioRet.length == 32) { isAdapter = true; _assertGraphInScopeAtFloor(abi.decode(ratioRet, (address)), depth + 1, keeperScope); }
        if (hasAsset && assetRet.length == 32) { isAdapter = true; _assertGraphInScopeAtFloor(abi.decode(assetRet, (address)), depth + 1, keeperScope); }
        if (isAdapter) return;

        (bool hasBound, bytes memory boundRet) = node.staticcall(abi.encodeWithSignature("rateMaxStaleness()"));
        if (!hasBound || boundRet.length != 32) return; // raw aggregator or constant adapter

        uint256 bound = abi.decode(boundRet, (uint256));
        (bool isVeda,) = node.staticcall(abi.encodeWithSignature("accountant()"));
        if (!keeperScope || isVeda) {
            require(bound >= REQUIRED_FLOOR, string.concat("leg below the 7d floor: ", vm.toString(node), " bound=", vm.toString(bound)));
        }

        (bool hasUnder, bytes memory underRet) = node.staticcall(abi.encodeWithSignature("underlyingUsdFeed()"));
        if (hasUnder && underRet.length == 32) {
            address under = abi.decode(underRet, (address));
            if (under != address(0)) _assertGraphInScopeAtFloor(under, depth + 1, keeperScope);
        }
    }

    // ---------------------------------------------------------------- hand-off

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
        string memory path = keeperOnly
            ? "output/3CP-657-Staleness7d-keeper-10.json"
            : "output/3CP-657-Staleness7d-all-10.json";
        vm.writeFile(path, json);
        console.log("");
        console.log(string.concat("wrote ", path, "  (drop-in for 3CP-Secure queued/657/optimism.json)"));
        console.log("  !! only submit this file if it came from a --broadcast run !!");
    }

    function _writeJson() internal {
        string memory json = "{";
        json = string.concat(json, '"phase":"', keeperOnly ? "keeper" : "all", '","aclManager":"', vm.toString(ACCESS_MANAGER), '","targetStaleness":"', vm.toString(TARGET), '"');
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
        string memory path = keeperOnly ? "output/Staleness7dFeedsOP-keeper.json" : "output/Staleness7dFeedsOP-all.json";
        vm.writeFile(path, json);
        console.log(string.concat("wrote ", path));
    }
}
