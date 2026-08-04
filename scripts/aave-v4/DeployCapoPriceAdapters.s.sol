// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IVedaAccountant } from "../../src/interfaces/IVedaAccountant.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { VedaAccountantPriceFeed } from "../../src/oracle/VedaAccountantPriceFeed.sol";
import { CLRatePriceCapAdapter } from "../../src/oracle/capo/vendor/CLRatePriceCapAdapter.sol";
import { EURPriceCapAdapterStable } from "../../src/oracle/capo/vendor/EURPriceCapAdapterStable.sol";
import { IACLManager } from "../../src/oracle/capo/vendor/IACLManager.sol";
import { IChainlinkAggregator } from "../../src/oracle/capo/vendor/IChainlinkAggregator.sol";
import { ICLSynchronicityPriceAdapter } from "../../src/oracle/capo/vendor/ICLSynchronicityPriceAdapter.sol";
import { IEURPriceCapAdapterStable } from "../../src/oracle/capo/vendor/IEURPriceCapAdapterStable.sol";
import { IPriceCapAdapter } from "../../src/oracle/capo/vendor/IPriceCapAdapter.sol";
import { IPriceCapAdapterStable } from "../../src/oracle/capo/vendor/IPriceCapAdapterStable.sol";
import { OneUSDFixedAdapter } from "../../src/oracle/capo/vendor/OneUSDFixedAdapter.sol";
import { PriceCapAdapterStable } from "../../src/oracle/capo/vendor/PriceCapAdapterStable.sol";

interface ISpokeLike {
    function getReserveCount() external view returns (uint256);
}

interface IAaveOracleLike {
    function decimals() external view returns (uint8);
    function getReserveSource(uint256 reserveId) external view returns (address);
    function getReservePrice(uint256 reserveId) external view returns (uint256);
}

interface ISpokeConfiguratorLike {
    function updateReservePriceSource(address spoke, uint256 reserveId, address priceSource) external;
}

/**
 * @title DeployCapoPriceAdapters
 * @notice Deploys the capped price adapter set for the ether.fi Cash Aave v4 instance on OP Mainnet,
 *         answering Aave's review point that our feeds were plugged in without a price adapter.
 *
 *         Architecture, per asset, bottom to top:
 *
 *           raw Chainlink aggregator / Veda accountant / Midas proxy
 *              -> ChainlinkPriceFeed or VedaAccountantPriceFeed
 *                                           (ours, Paladin-audited: staleness + fail-closed, scales)
 *                 -> Aave price cap adapter (unmodified from aave-price-feeds: growth or par cap)
 *                    -> AaveOracle          (requires decimals() == 8 and latestAnswer() > 0)
 *
 *         NO NEW CONTRACT IS INTRODUCED ANYWHERE IN THIS STACK. Every capping contract is Aave's
 *         own, unmodified. Every leg beneath one is an instance of a cash-v3 feed that is already
 *         Paladin-audited. Nothing here needs a new audit.
 *
 *         The `IACLManager` those adapters demand is satisfied by passing this instance's
 *         AccessManager, which implements neither `isRiskAdmin` nor `isPoolAdmin` — so the cap setters
 *         are permanently unreachable and the caps are immutable. See `_aclManager()`.
 *
 *         Our feeds sit UNDER Aave's adapters rather than over them because Aave's adapters read
 *         `latestAnswer()` with no age check and return 0 on a bad read. Putting ours underneath
 *         keeps the staleness guard (it reverts, which propagates through the adapter) and satisfies
 *         the only two functions Aave's adapters call on a source: `decimals()` and `latestAnswer()`.
 *         It also resolves three shape mismatches for free: Chainlink publishes ETHFI/USD at 18
 *         decimals, the Midas proxies expose only `latestRoundData()`, and a Veda accountant exposes
 *         neither `latestAnswer()` nor a usable precision (liquidUSD's rate is 6 decimals, below the
 *         8 Aave's cap base requires). None can feed an Aave adapter raw; all three work once wrapped.
 *
 *         WHAT THIS SCRIPT DOES NOT DO: it never repoints a reserve. `updateReservePriceSource` is
 *         deliberately held on the configurator domain-admin role (400, Owner Safe only), not the
 *         risk curator role, so the swap is an Owner Safe transaction. The script prints the exact
 *         calldata for that batch after verifying every adapter against the feed it replaces.
 *
 * Usage — dry run first (no --broadcast), which still runs every check:
 *   source .env && forge script scripts/aave-v4/DeployCapoPriceAdapters.s.sol:DeployCapoPriceAdapters \
 *     --rpc-url $OPTIMISM_RPC -vvv
 *
 * Then broadcast and verify:
 *   source .env && forge script scripts/aave-v4/DeployCapoPriceAdapters.s.sol:DeployCapoPriceAdapters \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvv
 */
contract DeployCapoPriceAdapters is Script {
    // ---------------------------------------------------------------- instance (OP Mainnet)
    address constant ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
    address constant SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    address constant OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

    // ---------------------------------------------------------------- Chainlink aggregators
    address constant ETH_USD = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address constant BTC_USD = 0xD702DD976Fb76Fffc2D3963D037dfDae5b04E593;
    address constant USDC_USD = 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3;
    address constant USDT_USD = 0xECef79E109e997bCA29c1c0897ec9d7b03647F5E;
    address constant EUR_USD = 0x3626369857A10CcC6cc3A6e4f5C2f5984a519F20;
    address constant OP_USD = 0x0D276FC14719f9292D5C1eA2198673d1f4269246;
    address constant WEETH_ETH_RATE = 0xb4479d436DDa5c1A79bD88D282725615202406E3; // 18 dec

    // newly commissioned for this market (all live on OP, all owned by the Chainlink feed admin)
    address constant EURC_USD = 0xDb2A51a5DD73865F1b0d1c33F99a96E0e7ae742c; // 8 dec
    address constant FRXUSD_USD = 0x14a2Aa4189Aed564bFB04071c99f308C7ffd5283; // 8 dec
    address constant ETHFI_USD = 0x9A3C975993354354080d815e313eEEdEb907fF34; // 18 dec
    address constant HYPE_USD = 0x961f6a07bFc62F618a4fA737eDe08F23aD6Da67F; // 8 dec
    address constant BEHYPE_RATE = 0x8792DD897CFB1F6e81dd6C7c4491f97ed79eaD24; // 18 dec, beHYPE/HYPE

    // ---------------------------------------------------------------- Midas proxies (8 dec)
    address constant LIQUID_RESERVE_USD = 0x58dDf77A329CcbE2F4C2114C64ed9E12Ec8a1356;
    address constant LIQUID_RWA_USD = 0xd5aaE6ac1a9ed4BE5DcC1fc172EDeFFd5B6d8080;
    address constant WEEUR_EUR = 0x01b910C1aa51cdC4a2a84d76CB255C4974Bf8A19;

    // ---------------------------------------------------------------- Veda accountants
    address constant EBTC_ACCOUNTANT = 0x1b293DC39F94157fA0D1D36d7e0090C8B8B8c13F; // 8 dec, base WBTC
    address constant EUSD_ACCOUNTANT = 0xEB440B36f61Bf62E0C54C622944545f159C3B790; // 18 dec, base USDe
    address constant SETHFI_ACCOUNTANT = 0x05A1552c5e18F5A0BB9571b5F2D6a4765ebdA32b; // 18 dec, base ETHFI
    address constant LIQUID_ETH_ACCOUNTANT = 0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198; // 18, WETH
    address constant LIQUID_BTC_ACCOUNTANT = 0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0; // 8, WBTC
    address constant LIQUID_USD_ACCOUNTANT = 0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7; // 6, USDC

    // ---------------------------------------------------------------- staleness bounds
    // Measured over the round history of each feed (see the launch notes). The 24h-heartbeat feeds
    // get 2x their heartbeat; the two fast, deviation-driven feeds get a far tighter bound; the
    // Midas proxies publish roughly every three days.
    uint256 constant STALENESS_HEARTBEAT_24H = 2 days; // USDC, USDT, ETH, BTC, EUR, EURC, frxUSD, OP, rate feeds
    uint256 constant STALENESS_FAST = 6 hours; // HYPE/USD (~34 updates/day), ETHFI/USD (~40/day)
    uint256 constant STALENESS_MIDAS = 7 days; // liquidRESERVE, liquidRWA, weEUR/EUR
    uint256 constant STALENESS_VEDA_RATE = 2 days; // accountantState().lastUpdateTimestamp

    /// @dev Precision of the Veda RATE leg. This is NOT the decimals AaveOracle sees — that comes
    ///      from the BASE leg and is always 8. `RATIO_DECIMALS` divides straight back out inside
    ///      `latestAnswer()` (price = basePrice x ratio / 10**RATIO_DECIMALS), so an 18-decimal rate
    ///      leg still produces an 8-decimal feed. Verified on the deployed set: `DECIMALS` reads 8 on
    ///      all eleven cap adapters.
    ///
    ///      8 would also produce a correct price, but 18 is deliberate and matches what Aave does in
    ///      their own adapter for our eBTC vault, which multiplies the 8-decimal accountant rate by
    ///      1e10 with the comment: "Considering the current configuration of
    ///      maxYearlyRatioGrowthPercent, it is necessary to add an extra precision of 1e10 to ensure
    ///      that maxRatioGrowthPerSecond is accurately configured."
    ///
    ///      Concretely, `maxRatioGrowthPerSecondScaled` is integer-divided and floors to zero below
    ///      317. At 18 decimals our legs sit at 2.5e14-4.5e15; at 8 they would sit near 2.5e4, about
    ///      1e10 closer to silently pinning the ceiling flat.
    ///
    ///      IF YOU CHANGE THIS, CHANGE EVERY SNAP_* VEDA CONSTANT TO MATCH. The snapshot must be in
    ///      the same units the leg returns. Changing only one side is not a compile error and one
    ///      direction is not even a visible one — see the scale check in `_assertCapWiring`.
    ///
    ///      Native accountant precisions: 8 for the WBTC vaults, 18 for WETH/ETHFI/USDe, 6 for
    ///      liquidUSD. Aave's cap base rejects a ratio precision below 8, so liquidUSD cannot be
    ///      passed raw regardless.
    uint8 constant VEDA_RATE_DECIMALS = 18;

    uint8 constant USD_FEED_DECIMALS = 8;

    // ---------------------------------------------------------------- cap parameters
    // $1.04, matching Aave everywhere they cap a USD stable: V3 OP, and their own V4 Ethereum and
    // V4 Avalanche instances (frxUSD included, at `0x25DEd2f9` on Ethereum). A tighter par cap was
    // considered and dropped: `PriceCapAdapterStable` refuses to deploy while the feed prints above
    // the cap, and frxUSD sits fractionally above $1 much of the time, so a par cap would make the
    // deploy depend on catching the feed on a down-tick.
    int256 constant STABLE_PRICE_CAP = 1.04e8;
    /// @dev EURC is capped at 1.04x the EUR/USD price rather than a fixed dollar figure
    int256 constant EUR_PRICE_CAP_RATIO = 1.04e8;
    uint8 constant EUR_PRICE_CAP_RATIO_DECIMALS = 8;

    /// @dev Snapshots are taken 60 days back, not 7.
    ///
    ///      The cap only refuses to construct if the ceiling has already been overtaken by the rate
    ///      realised between the snapshot and now, so the snapshot window is what decides whether a
    ///      given cap is deployable at all. Over 7 days that realised figure is noise: these
    ///      publishers update every few days, so one lumpy week reads far above true yield. sETHFI
    ///      measured 10.99%/yr over 7 days against ~7.7% across every multi-week window, and weEUR
    ///      9.83% against ~6.7% — both would have made the reviewer's 9% caps undeployable for no
    ///      real reason.
    ///
    ///      A 60-day window also leaves a healthier operating buffer. The gap between ceiling and
    ///      spot grows with the elapsed time since the snapshot, so a 7-day snapshot puts the ceiling
    ///      only ~0.03% above spot — one unusual publish and it binds, under-pricing collateral. At
    ///      60 days it sits ~0.3-0.4% above. Aave goes much further still: their live wstETH adapter
    ///      snapshots from February 2024.
    ///
    ///      MINIMUM_SNAPSHOT_DELAY stays at Aave's 7 days. It is a floor on how fresh a snapshot may
    ///      be, not a target, and keeping it low leaves room for future re-snapshots.
    ///
    ///      Aave's base also rejects a snapshot older than 180 days, which puts a deploy deadline on
    ///      these values — see the README note in the pull request.
    uint48 constant SNAPSHOT_DELAY = 7 days;
    uint48 constant SNAPSHOT_TS_VEDA = 1_780_627_963; // 60 days back
    uint48 constant SNAPSHOT_TS_MIDAS = 1_780_627_963; // 60 days back

    /// @dev liquidRWA's feed launched at exactly 1.00000000 about 60 days ago, so a 60-day snapshot
    ///      would land on its first published round. Taken 45 days back to clear that edge.
    uint48 constant SNAPSHOT_TS_LIQUID_RWA = 1_781_923_963;

    /// @dev beHYPE's Chainlink rate feed is only ~6 days old, so there is no 60-day reading to take.
    ///      Snapshot is its first published round and the delay is loosened to match. RE-SNAPSHOT
    ///      once the feed has a month of history.
    uint48 constant SNAPSHOT_DELAY_BEHYPE = 3 days;
    uint48 constant SNAPSHOT_TS_BEHYPE = 1_785_344_431;

    // maxYearlyRatioGrowthPercent, in bps of the snapshot ratio. SET BY RISK REVIEW.
    //
    // These are not derived from a formula — each one is a risk decision, with the reasoning the
    // reviewer gave. Do not "recompute" them from observed yield without going back to risk.
    uint16 constant GROWTH_SETHFI = 1200; // 12.00% — raised from 9.00% on the reviewer's call
    uint16 constant GROWTH_LIQUID_USD = 750; //  7.50%
    uint16 constant GROWTH_LIQUID_RESERVE = 650; //  6.50% — allows for a higher-yielding strategy coming
    uint16 constant GROWTH_LIQUID_ETH = 500; //  5.00%
    uint16 constant GROWTH_LIQUID_RWA = 900; //  9.00% — reviewer flagged this can tighten later
    uint16 constant GROWTH_BEHYPE = 300; //  3.00%
    uint16 constant GROWTH_WEETH = 500; //  5.00%
    uint16 constant GROWTH_EBTC = 100; //  1.00% — deliberately loose, small TVL
    uint16 constant GROWTH_EUSD = 75; //  0.75% — deliberately loose, small TVL
    uint16 constant GROWTH_WEEUR = 900; //  9.00% — Midas is instructed not to post an update
        //           implying more than 7.5%, so this sits just above that contractual bound
    //
    // liquidBTC: PROPOSED, NOT YET CONFIRMED BY RISK. Set to match beHYPE, whose observed growth is
    // near-identical (1.81% vs 1.74% realised over the snapshot window). Confirm before deploy.
    uint16 constant GROWTH_LIQUID_BTC = 300; //  3.00% — PROPOSED, awaiting confirmation

    // Snapshot ratios, read 60 days back, in the units the matching getRatio() returns: 18 decimals
    // for every Veda rate leg, and the leg's own decimals otherwise.
    uint104 constant SNAP_EBTC = 1_003_626_440_000_000_000; // raw 100362644, 8 dec, x1e10
    uint104 constant SNAP_LIQUID_BTC = 1_029_351_010_000_000_000; // raw 102935101, 8 dec, x1e10
    uint104 constant SNAP_LIQUID_USD = 1_160_589_000_000_000_000; // raw 1160589, 6 dec, x1e12
    uint104 constant SNAP_EUSD = 1_065_594_833_004_492_070;
    uint104 constant SNAP_SETHFI = 1_187_971_295_403_462_986;
    uint104 constant SNAP_LIQUID_ETH = 1_094_734_190_917_310_748;
    uint104 constant SNAP_WEETH = 1_095_883_047_457_899_600;
    uint104 constant SNAP_BEHYPE = 1_018_457_451_127_239_140;
    uint104 constant SNAP_LIQUID_RESERVE = 101_921_231; // 8 dec
    uint104 constant SNAP_LIQUID_RWA = 100_306_638; // 8 dec
    uint104 constant SNAP_WEEUR = 100_205_896; // 8 dec

    /// @dev A new adapter must price within this much of the feed it replaces, in bps. Wide enough to
    ///      absorb the stable de-snap (up to 1%) and the Pyth -> Chainlink provider switch on the
    ///      volatile assets (ETHFI was ~1.5% apart between the two providers when measured), tight
    ///      enough to catch the failure classes that actually matter: a decimals slip or a missing
    ///      composition leg is off by orders of magnitude, never by single-digit percent.
    uint256 constant PRICE_TOLERANCE_BPS = 500;

    // ---------------------------------------------------------------- reserve ids
    // Fixed at listing time and never reassigned; confirmed against the live spoke.
    uint256 constant RESERVE_USDC = 0;
    uint256 constant RESERVE_USDT = 2;
    uint256 constant RESERVE_EURC = 3;
    uint256 constant RESERVE_FRXUSD = 4;
    uint256 constant RESERVE_WEETH = 5;
    uint256 constant RESERVE_EBTC = 6;
    uint256 constant RESERVE_EUSD = 7;
    uint256 constant RESERVE_ETHFI = 8;
    uint256 constant RESERVE_SETHFI = 9;
    uint256 constant RESERVE_WHYPE = 11;
    uint256 constant RESERVE_BEHYPE = 12;
    uint256 constant RESERVE_LIQUIDETH = 13;
    uint256 constant RESERVE_LIQUIDBTC = 14;
    uint256 constant RESERVE_LIQUIDUSD = 15;
    uint256 constant RESERVE_LIQUIDRESERVE = 16;
    uint256 constant RESERVE_WEEUR = 17;
    uint256 constant RESERVE_LIQUIDRWA = 18;

    // ---------------------------------------------------------------- outputs

    struct Result {
        string symbol;
        uint256 reserveId;
        address adapter;
        address replaces;
        uint256 newPrice;
        uint256 oldPrice;
        bool capped;
        bool isParCapped;
    }

    Result[] results;

    /// @dev The shared inner feeds, in storage rather than as locals in `run()`: fifteen addresses
    ///      plus the adapter calls overflow the stack otherwise, and every one of them is read from
    ///      more than one place.
    struct Legs {
        // USD legs, all 8 decimals
        address ethUsd;
        address btcUsd;
        address usdcUsd;
        address usdtUsd;
        address frxUsdUsd;
        address eurUsd;
        address eurcUsd;
        address ethfiUsd;
        address hypeUsd;
        address oneUsd;
        // rate legs, in native precision
        address weethRate;
        address behypeRate;
        address liquidReserveRate;
        address liquidRwaRate;
        address weeurRate;
    }

    Legs legs;

    function run() public {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        require(IAaveOracleLike(AAVE_ORACLE).decimals() == USD_FEED_DECIMALS, "oracle is not 8 decimals");

        _preflightStableCaps();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _deployLegs();
        _deployAdapters();
        vm.stopBroadcast();

        _verify();
        _printSafeBatch();
        _writeJson();
    }

    /// @dev `PriceCapAdapterStable` reverts with `CapLowerThanActualPrice` if the cap is below the
    ///      feed's current answer. With a par cap that happens whenever a stable trades above $1, so
    ///      say which asset and by how much here rather than letting the constructor fail opaquely
    ///      halfway through a broadcast.
    function _preflightStableCaps() internal view {
        console.log("=== par-cap preflight ===");
        _checkStableCap("USDC", USDC_USD, STABLE_PRICE_CAP);
        _checkStableCap("USDT", USDT_USD, STABLE_PRICE_CAP);
        _checkStableCap("frxUSD", FRXUSD_USD, STABLE_PRICE_CAP);
    }

    function _checkStableCap(string memory sym, address aggregator, int256 priceCap) internal view {
        int256 answer = IChainlinkAggregator(aggregator).latestAnswer();
        if (answer > priceCap) {
            console.log(
                string.concat(
                    "  BLOCKED ",
                    sym,
                    ": feed is ",
                    vm.toString(answer),
                    " but the cap is ",
                    vm.toString(priceCap),
                    " - PriceCapAdapterStable will revert. Either wait for the feed to print at or",
                    " below par, or raise this asset's cap."
                )
            );
        } else {
            console.log(string.concat("  ok ", sym, ": feed ", vm.toString(answer), " <= cap ", vm.toString(priceCap)));
        }
        require(answer <= priceCap, string.concat(sym, ": price above the configured cap, see above"));
    }

    /// @dev Aave's adapters take an `IACLManager` and reject `address(0)`, but they use it for exactly
    ///      one thing: gating `setCapParameters` / `setPriceCap`. Aave's own V4 instances satisfy it by
    ///      passing the Aave V3 ACLManager on the same chain (V4 Ethereum -> `0xc2aaCf65`, V4
    ///      Avalanche -> `0xa72636Cb`), which works for them because Aave governance owns both V3 and
    ///      V4 there. A whitelabel instance has no V3 pool to borrow a role registry from.
    ///
    ///      So we pass this instance's AccessManager. It does not implement `isRiskAdmin` or
    ///      `isPoolAdmin`, so those calls revert and the cap setters are permanently unreachable: the
    ///      caps are immutable, and retuning one means deploying a fresh adapter and repointing the
    ///      reserve — the same two steps this script and its Owner Safe batch already perform.
    ///
    ///      That is not a downgrade from Aave's own practice. Their live V3 OP wstETH adapter
    ///      (`0x724E4719`) still carries its February 2024 snapshot and a 9.68% growth rate, untouched
    ///      in over two years; BGD redeploys and repoints rather than calling the setters. Immutable
    ///      caps also remove the setter as an attack surface entirely.
    ///
    ///      The cost is real and worth stating: Nonce cannot retune a cap on their own. A cap change
    ///      becomes an Owner Safe action, like every other price source change on this spoke.
    function _aclManager() internal pure returns (IACLManager) {
        return IACLManager(ACCESS_MANAGER);
    }

    function _deployLegs() internal {
        // ---- staleness-checked USD legs, shared as both direct sources and adapter bases
        legs.ethUsd = _feed(ETH_USD, address(0), USD_FEED_DECIMALS, STALENESS_HEARTBEAT_24H, "ETH / USD");
        legs.btcUsd = _feed(BTC_USD, address(0), USD_FEED_DECIMALS, STALENESS_HEARTBEAT_24H, "BTC / USD");
        legs.usdcUsd = _feed(USDC_USD, address(0), USD_FEED_DECIMALS, STALENESS_HEARTBEAT_24H, "USDC / USD");
        legs.usdtUsd = _feed(USDT_USD, address(0), USD_FEED_DECIMALS, STALENESS_HEARTBEAT_24H, "USDT / USD");
        legs.frxUsdUsd = _feed(FRXUSD_USD, address(0), USD_FEED_DECIMALS, STALENESS_HEARTBEAT_24H, "frxUSD / USD");
        legs.eurUsd = _feed(EUR_USD, address(0), USD_FEED_DECIMALS, STALENESS_HEARTBEAT_24H, "EUR / USD");
        legs.eurcUsd = _feed(EURC_USD, address(0), USD_FEED_DECIMALS, STALENESS_HEARTBEAT_24H, "EURC / USD");
        // Chainlink publishes these two at 18 decimals; the wrapper normalises them to 8
        legs.ethfiUsd = _feed(ETHFI_USD, address(0), USD_FEED_DECIMALS, STALENESS_FAST, "ETHFI / USD");
        legs.hypeUsd = _feed(HYPE_USD, address(0), USD_FEED_DECIMALS, STALENESS_FAST, "HYPE / USD");
        // A fixed $1 base, used only by liquidRESERVE, liquidRWA and eUSD.
        //
        // READ THIS BEFORE REUSING IT. `CLRatePriceCapAdapter` caps the RATIO only — the base USD
        // price passes through untouched — so for a genuine exchange-rate asset the USD price stays
        // free to move with its base asset. weETH/USD is ETH/USD x min(weETH/ETH, ceiling): if ETH
        // doubles, weETH/USD doubles. That is the whole point of the shape.
        //
        // These three are different: the quantity in the ratio slot is already USD-denominated, so
        // pairing it with a $1 base means the growth cap bounds a USD price directly. That is only
        // ever correct for a pure accrual with no market exposure, and wrong for anything carrying
        // market risk, where a legitimate rally would be clamped and the collateral under-priced.
        //
        // It holds here: sampled every 10 days over the trailing 90, all three are strictly monotone
        // increasing with zero down-ticks (liquidRESERVE 1.01576 -> 1.02596, liquidRWA 1.00000 ->
        // 1.01186 since it launched ~60 days ago, weEUR/EUR 1.00000 -> 1.01303). They are yield share
        // prices that only accrete, and they have no market leg to anchor them — which makes them the
        // assets that need a growth cap most, not least.
        //
        // RE-CHECK THIS IF THE VAULT MANDATES CHANGE. If liquidRWA ever takes real market exposure —
        // gold, for instance — capping its NAV growth becomes the wrong tool and this base must be
        // replaced with that asset's USD feed.
        //
        // Note also that Aave documents `OneUSDFixedAdapter` as a standalone $1 price source and does
        // not use it as a cap base anywhere. Flag this construction in the Aave review rather than
        // letting them discover it.
        legs.oneUsd = address(new OneUSDFixedAdapter());
        console.log("OneUSDFixedAdapter          ", legs.oneUsd);

        // ---- staleness-checked RATE legs, kept in their native precision for the cap math
        legs.weethRate = _feed(WEETH_ETH_RATE, address(0), 18, STALENESS_HEARTBEAT_24H, "weETH / ETH rate");
        legs.behypeRate = _feed(BEHYPE_RATE, address(0), 18, STALENESS_HEARTBEAT_24H, "beHYPE / HYPE rate");
        legs.liquidReserveRate =
            _feed(LIQUID_RESERVE_USD, address(0), 8, STALENESS_MIDAS, "liquidRESERVE / USD rate");
        legs.liquidRwaRate = _feed(LIQUID_RWA_USD, address(0), 8, STALENESS_MIDAS, "liquidRWA / USD rate");
        legs.weeurRate = _feed(WEEUR_EUR, address(0), 8, STALENESS_MIDAS, "weEUR / EUR rate");
    }

    function _deployAdapters() internal {
        // ================================================================ uncapped market prices
        // Aave leaves volatile market feeds uncapped on V3 OP too — WETH and OP read the raw
        // aggregator there, with no adapter at all. So these two only swap the price PROVIDER
        // (Pyth -> Chainlink); there is nothing to cap.
        //
        // WETH and OP are deliberately NOT in this list. Their live feeds are already
        // Chainlink-rooted, staleness-checked and non-snapping, so repointing them would change
        // nothing and would only add two transactions to the Owner Safe batch. The ETH/USD leg is
        // still deployed above because weETH and liquidETH compose against it.
        _record("ETHFI", legs.ethfiUsd, RESERVE_ETHFI);
        _record("wHYPE", legs.hypeUsd, RESERVE_WHYPE);

        // ================================================================ fixed caps: USD stables
        _record("USDC", _stable(legs.usdcUsd, STABLE_PRICE_CAP, "Capped USDC / USD"), RESERVE_USDC, true);
        _record("USDT", _stable(legs.usdtUsd, STABLE_PRICE_CAP, "Capped USDT / USD"), RESERVE_USDT, true);
        _record("frxUSD", _stable(legs.frxUsdUsd, STABLE_PRICE_CAP, "Capped frxUSD / USD"), RESERVE_FRXUSD, true);

        // ================================================================ fixed cap: EUR peg
        _record("EURC", _eurStable(legs.eurcUsd, legs.eurUsd, "Capped EURC / EUR / USD"), RESERVE_EURC);

        // ================================================================ growth caps: Chainlink rates
        _record(
            "weETH",
            _clRate(legs.ethUsd, legs.weethRate, "Capped weETH / ETH / USD", SNAP_WEETH, SNAPSHOT_TS_VEDA, GROWTH_WEETH, SNAPSHOT_DELAY),
            RESERVE_WEETH
        );
        _record(
            "beHYPE",
            _clRate(legs.hypeUsd, legs.behypeRate, "Capped beHYPE / HYPE / USD", SNAP_BEHYPE, SNAPSHOT_TS_BEHYPE, GROWTH_BEHYPE, SNAPSHOT_DELAY_BEHYPE),
            RESERVE_BEHYPE
        );

        // ================================================================ growth caps: Midas NAV
        _record(
            "liquidRESERVE",
            _clRate(legs.oneUsd, legs.liquidReserveRate, "Capped liquidRESERVE / USD", SNAP_LIQUID_RESERVE, SNAPSHOT_TS_MIDAS, GROWTH_LIQUID_RESERVE, SNAPSHOT_DELAY),
            RESERVE_LIQUIDRESERVE
        );
        _record(
            "liquidRWA",
            _clRate(legs.oneUsd, legs.liquidRwaRate, "Capped liquidRWA / USD", SNAP_LIQUID_RWA, SNAPSHOT_TS_LIQUID_RWA, GROWTH_LIQUID_RWA, SNAPSHOT_DELAY),
            RESERVE_LIQUIDRWA
        );
        _record(
            "weEUR",
            _clRate(legs.eurUsd, legs.weeurRate, "Capped weEUR / EUR / USD", SNAP_WEEUR, SNAPSHOT_TS_MIDAS, GROWTH_WEEUR, SNAPSHOT_DELAY),
            RESERVE_WEEUR
        );

        // ================================================================ growth caps: Veda vaults
        _record(
            "eBTC",
            _veda(legs.btcUsd, EBTC_ACCOUNTANT, "Capped eBTC / BTC / USD", SNAP_EBTC, GROWTH_EBTC),
            RESERVE_EBTC
        );
        _record(
            "liquidBTC",
            _veda(legs.btcUsd, LIQUID_BTC_ACCOUNTANT, "Capped liquidBTC / BTC / USD", SNAP_LIQUID_BTC, GROWTH_LIQUID_BTC),
            RESERVE_LIQUIDBTC
        );
        _record(
            "liquidETH",
            _veda(legs.ethUsd, LIQUID_ETH_ACCOUNTANT, "Capped liquidETH / ETH / USD", SNAP_LIQUID_ETH, GROWTH_LIQUID_ETH),
            RESERVE_LIQUIDETH
        );
        _record(
            "liquidUSD",
            _veda(legs.usdcUsd, LIQUID_USD_ACCOUNTANT, "Capped liquidUSD / USDC / USD", SNAP_LIQUID_USD, GROWTH_LIQUID_USD),
            RESERVE_LIQUIDUSD
        );
        _record(
            "sETHFI",
            _veda(legs.ethfiUsd, SETHFI_ACCOUNTANT, "Capped sETHFI / ETHFI / USD", SNAP_SETHFI, GROWTH_SETHFI),
            RESERVE_SETHFI
        );
        // eUSD's vault is denominated in USDe and there is no USDe/USD feed on OP, so the base leg is
        // a fixed $1 — the same assumption the current feed makes implicitly, now explicit and
        // growth-capped. Replace `legs.oneUsd` with a real USDe/USD feed as soon as one exists.
        _record(
            "eUSD",
            _veda(legs.oneUsd, EUSD_ACCOUNTANT, "Capped eUSD / USDe(1 USD) / USD", SNAP_EUSD, GROWTH_EUSD),
            RESERVE_EUSD
        );

    }

    // ------------------------------------------------------------------ deploy helpers

    /// @dev One of our staleness-checked feeds. `underlying == address(0)` means the source is
    ///      already quoted in the target unit and is only rescaled.
    function _feed(address source, address underlying, uint8 feedDecimals, uint256 maxStaleness, string memory desc)
        internal
        returns (address)
    {
        // isStableToken is always false here: the +/-1% snap to exactly $1 is what Aave objected to,
        // and PriceCapAdapterStable replaces it with an upside-only cap.
        address feed = address(
            new ChainlinkPriceFeed(
                IAggregatorV3(source), IAaveV4PriceFeed(underlying), feedDecimals, maxStaleness, false, desc
            )
        );
        require(IAaveV4PriceFeed(feed).latestAnswer() > 0, string.concat("dead leg: ", desc));
        console.log("  leg", desc, feed);
        return feed;
    }

    function _stable(address assetUsdFeed, int256 priceCap, string memory desc) internal returns (address) {
        return address(
            new PriceCapAdapterStable(
                IPriceCapAdapterStable.CapAdapterStableParams({
                    aclManager: _aclManager(),
                    assetToUsdAggregator: IChainlinkAggregator(assetUsdFeed),
                    adapterDescription: desc,
                    priceCap: priceCap
                })
            )
        );
    }

    function _eurStable(address assetUsdFeed, address eurUsdFeed, string memory desc) internal returns (address) {
        return address(
            new EURPriceCapAdapterStable(
                IEURPriceCapAdapterStable.CapAdapterStableParamsEUR({
                    aclManager: _aclManager(),
                    assetToUsdAggregator: IChainlinkAggregator(assetUsdFeed),
                    baseToUsdAggregator: IChainlinkAggregator(eurUsdFeed),
                    adapterDescription: desc,
                    ratioDecimals: EUR_PRICE_CAP_RATIO_DECIMALS,
                    priceCapRatio: EUR_PRICE_CAP_RATIO
                })
            )
        );
    }

    function _clRate(
        address baseUsdFeed,
        address rateFeed,
        string memory desc,
        uint104 snapshotRatio,
        uint48 snapshotTimestamp,
        uint16 growthBps,
        uint48 snapshotDelay
    ) internal returns (address) {
        return address(
            new CLRatePriceCapAdapter(
                IPriceCapAdapter.CapAdapterParams({
                    aclManager: _aclManager(),
                    baseAggregatorAddress: baseUsdFeed,
                    ratioProviderAddress: rateFeed,
                    pairDescription: desc,
                    minimumSnapshotDelay: snapshotDelay,
                    priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
                        snapshotRatio: snapshotRatio,
                        snapshotTimestamp: snapshotTimestamp,
                        maxYearlyRatioGrowthPercent: growthBps
                    })
                })
            )
        );
    }

    /// @dev A Veda vault. The rate leg is one of our own audited `VedaAccountantPriceFeed`s with no
    ///      underlying feed, so it returns the accountant's exchange rate normalised to 18 decimals
    ///      while still rejecting a paused or stale accountant. Aave's unmodified
    ///      `CLRatePriceCapAdapter` then reads it through `latestAnswer()` and applies the growth cap.
    ///      No bespoke adapter is involved on either layer.
    function _veda(address baseUsdFeed, address accountant, string memory desc, uint104 snapshotRatio, uint16 growthBps)
        internal
        returns (address)
    {
        address rateFeed = address(
            new VedaAccountantPriceFeed(
                IVedaAccountant(accountant),
                IAaveV4PriceFeed(address(0)),
                VEDA_RATE_DECIMALS,
                STALENESS_VEDA_RATE,
                false,
                string.concat(desc, " rate")
            )
        );
        console.log("  leg", string.concat(desc, " rate"), rateFeed);
        return _clRate(baseUsdFeed, rateFeed, desc, snapshotRatio, SNAPSHOT_TS_VEDA, growthBps, SNAPSHOT_DELAY);
    }

    /// @dev Registers a finished adapter against the reserve it will be installed on. The feed it
    ///      replaces is read from the oracle at verification time rather than hardcoded: the live
    ///      sources have already been changed once during this review round (EURC, frxUSD and wHYPE
    ///      were repointed straight at raw Chainlink aggregators), and a stale constant here would
    ///      silently drop an asset out of the batch. Reserve ids, by contrast, never change once
    ///      listed.
    function _record(string memory symbol, address adapter, uint256 reserveId) internal {
        _record(symbol, adapter, reserveId, false);
    }

    function _record(string memory symbol, address adapter, uint256 reserveId, bool isParCapped) internal {
        results.push(
            Result({
                symbol: symbol,
                reserveId: reserveId,
                adapter: adapter,
                replaces: address(0),
                newPrice: 0,
                oldPrice: 0,
                capped: false,
                isParCapped: isParCapped
            })
        );
        console.log(string.concat("adapter  ", symbol), adapter);
    }

    // ------------------------------------------------------------------ verification

    /// @dev Every check here is fatal. A silently wrong price feed is the worst failure mode this
    ///      market has, so the script refuses to finish rather than print a warning.
    function _verify() internal {
        console.log("");
        console.log("=== verification ===");
        uint256 reserveCount = ISpokeLike(SPOKE).getReserveCount();
        for (uint256 i; i < results.length; i++) {
            Result storage r = results[i];
            string memory sym = r.symbol;

            require(r.reserveId < reserveCount, string.concat(sym, ": reserve id is not listed on the spoke"));
            r.replaces = IAaveOracleLike(AAVE_ORACLE).getReserveSource(r.reserveId);

            uint8 dec = ICLSynchronicityPriceAdapter(r.adapter).decimals();
            require(dec == USD_FEED_DECIMALS, string.concat(sym, ": adapter decimals != 8, AaveOracle would reject it"));
            _assertCapWiring(sym, r.adapter);

            int256 newAnswer = ICLSynchronicityPriceAdapter(r.adapter).latestAnswer();
            require(newAnswer > 0, string.concat(sym, ": adapter returned a non-positive price"));

            // Compares against the oracle rather than the old feed directly, so this works whether
            // the live source is one of our adapters or a raw aggregator.
            uint256 livePrice = IAaveOracleLike(AAVE_ORACLE).getReservePrice(r.reserveId);
            require(livePrice > 0, string.concat(sym, ": the live reserve price is zero"));
            int256 oldAnswer = int256(livePrice);

            // casting to 'uint256' is safe because both answers are require'd positive just above
            // forge-lint: disable-next-line(unsafe-typecast)
            r.newPrice = uint256(newAnswer);
            // forge-lint: disable-next-line(unsafe-typecast)
            r.oldPrice = uint256(oldAnswer);

            uint256 diff = r.newPrice > r.oldPrice ? r.newPrice - r.oldPrice : r.oldPrice - r.newPrice;
            uint256 driftBps = (diff * 10_000) / r.oldPrice;
            require(driftBps <= PRICE_TOLERANCE_BPS, string.concat(sym, ": price drifted too far from the live feed"));

            // For a GROWTH cap, being capped on day one means the ceiling already sits below the real
            // rate and collateral would be under-priced immediately - a bad parameter, not a warning.
            // For a PAR cap it just means the stable is trading above $1, which is the whole point, so
            // the drift check above is the only guard those need.
            r.capped = _isCapped(r.adapter);
            require(
                !r.capped || r.isParCapped,
                string.concat(sym, ": growth cap is already binding, raise maxYearlyRatioGrowthPercent")
            );

            // Single-string logs throughout: the console.log(string, uint256) overload renders
            // inconsistently across forge-std versions, and this output is the audit trail.
            console.log(
                string.concat(
                    "  ok ",
                    sym,
                    "  new=",
                    vm.toString(r.newPrice),
                    "  live=",
                    vm.toString(r.oldPrice),
                    "  drift=",
                    vm.toString(driftBps),
                    "bps"
                )
            );
        }
    }

    /// @dev Checks the decimal plumbing inside a growth-cap adapter, which is invisible from the
    ///      outside and where a mistake would be silent rather than loud.
    ///
    ///      The layers use different precisions on purpose. `decimals()` — the only one AaveOracle
    ///      sees — is inherited from the BASE leg, so it is 8 because every base we pass is an 8-decimal
    ///      USD feed. `RATIO_DECIMALS` is the precision of the RATE leg, which is 18 for the Veda and
    ///      Chainlink rate feeds and 8 for the Midas NAV proxies, and it divides straight back out in
    ///      `latestAnswer()`: price = basePrice x ratio / 10**RATIO_DECIMALS. So an 18-decimal rate leg
    ///      does not make an 18-decimal feed.
    ///
    ///      The hazard worth asserting is `maxRatioGrowthPerSecond`. It is derived as
    ///      `snapshotRatio * growthBps * 1e6 / 1e4 / SECONDS_PER_YEAR` with integer division, so a
    ///      small snapshot combined with a small growth rate can floor it to ZERO — the ceiling would
    ///      then sit flat at the snapshot forever, clamping the price permanently. Nothing in Aave's
    ///      constructor rejects that. An 8-decimal ratio leg carries ~1e10 less headroom above the
    ///      floor than an 18-decimal one, so the Midas assets are where it would bite first.
    function _assertCapWiring(string memory sym, address adapter) internal view {
        // Discriminate on getMaxRatioGrowthPerSecondScaled(), which only PriceCapAdapterBase has.
        // Do NOT discriminate on RATIO_DECIMALS(): EURPriceCapAdapterStable exposes that name too, for
        // an unrelated quantity — there it is the precision of the cap RATIO (1.04e8), not of a rate
        // leg — and it has no DECIMALS() getter at all, only a lowercase `decimals` state variable.
        (bool okGrowth, bytes memory growthRet) =
            adapter.staticcall(abi.encodeWithSignature("getMaxRatioGrowthPerSecondScaled()"));
        if (!okGrowth || growthRet.length != 32) return; // a stable cap or a plain feed

        require(
            abi.decode(growthRet, (uint256)) > 0,
            string.concat(sym, ": growth rate floored to zero - the ceiling would never rise, pinning the price")
        );

        (bool okBase, bytes memory baseRet) = adapter.staticcall(abi.encodeWithSignature("DECIMALS()"));
        require(
            okBase && baseRet.length == 32 && abi.decode(baseRet, (uint8)) == USD_FEED_DECIMALS,
            string.concat(sym, ": cap base leg is not 8 decimals")
        );

        (bool okRatio, bytes memory ratioRet) = adapter.staticcall(abi.encodeWithSignature("RATIO_DECIMALS()"));
        uint8 ratioDecimals = abi.decode(ratioRet, (uint8));
        require(
            okRatio && ratioDecimals >= 8 && ratioDecimals <= 24,
            string.concat(sym, ": ratio decimals outside the 8-24 range Aave's cap base accepts")
        );

        // The snapshot ratio must be expressed in the SAME units the rate leg returns. Get that wrong
        // and one direction is loud while the other is silent:
        //
        //   snapshot too small (say 1e8 against an 18-decimal leg) -> the ceiling sits far below the
        //     rate, the price is clamped to near zero, and every position holding the asset becomes
        //     instantly liquidatable. The isCapped check above catches this.
        //
        //   snapshot too large (an 18-decimal snapshot against an 8-decimal leg) -> the ceiling sits
        //     1e10 above the rate, so it can never bind. The price stays perfectly correct, isCapped
        //     stays false, and every other check here passes — the growth cap is simply GONE. Nothing
        //     else in this script would notice, which is why this comparison exists.
        //
        // Real drift is tiny: these snapshots are 60 days old and the caps are single-digit percent,
        // so a couple of percent at most. A 2x band catches any scale error with room to spare.
        (bool okSnap, bytes memory snapRet) = adapter.staticcall(abi.encodeWithSignature("getSnapshotRatio()"));
        (bool okCur, bytes memory curRet) = adapter.staticcall(abi.encodeWithSignature("getRatio()"));
        require(okSnap && okCur, string.concat(sym, ": cannot read the snapshot or current ratio"));
        uint256 snapshotRatio = abi.decode(snapRet, (uint256));
        uint256 currentRatio = abi.decode(curRet, (uint256));
        require(
            snapshotRatio <= currentRatio * 2 && snapshotRatio * 2 >= currentRatio,
            string.concat(sym, ": snapshot ratio is not in the rate leg's units - scale mismatch, cap would be void")
        );
    }

    /// @dev The uncapped market feeds have no isCapped(); a failed call means "not a cap adapter".
    function _isCapped(address adapter) internal view returns (bool) {
        (bool ok, bytes memory ret) = adapter.staticcall(abi.encodeWithSignature("isCapped()"));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    // ------------------------------------------------------------------ hand-off

    /// @dev One call per adapter, in the order recorded. Run only after `_verify()`, which is what
    ///      fills in `replaces` and refuses to continue if anything looks wrong.
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
                vm.toString(
                    abi.encodeCall(ISpokeConfiguratorLike.updateReservePriceSource, (SPOKE, r.reserveId, r.adapter))
                )
            );
        }
    }

    function _writeJson() internal {
        string memory json = "{";
        json = string.concat(json, '"aclManager":"', vm.toString(ACCESS_MANAGER), '"');
        for (uint256 i; i < results.length; i++) {
            json = string.concat(
                json,
                ',"',
                results[i].symbol,
                '":{"adapter":"',
                vm.toString(results[i].adapter),
                '","replaces":"',
                vm.toString(results[i].replaces),
                '","price":"',
                vm.toString(results[i].newPrice),
                '"}'
            );
        }
        json = string.concat(json, "}");
        vm.writeFile("output/CapoPriceAdaptersOP.json", json);
        console.log("");
        console.log("wrote output/CapoPriceAdaptersOP.json");
    }
}
