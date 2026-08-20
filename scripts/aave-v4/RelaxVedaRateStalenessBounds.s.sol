// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IVedaAccountant } from "../../src/interfaces/IVedaAccountant.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { VedaAccountantPriceFeed } from "../../src/oracle/VedaAccountantPriceFeed.sol";
import { CLRatePriceCapAdapter } from "../../src/oracle/capo/vendor/CLRatePriceCapAdapter.sol";
import { IACLManager } from "../../src/oracle/capo/vendor/IACLManager.sol";
import { ICLSynchronicityPriceAdapter } from "../../src/oracle/capo/vendor/ICLSynchronicityPriceAdapter.sol";
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
 * @title RelaxVedaRateStalenessBounds
 * @notice 3CP-657. Raises the staleness bound on the four Veda vault RATE legs of the ether.fi Cash
 *         Aave v4 instance on OP Mainnet from 2 days to 7 days, and rebuilds the four cap adapters
 *         that bake those legs in immutably.
 *
 *           sETHFI    rate  2d -> 7d   (reserve 9)
 *           liquidETH rate  2d -> 7d   (reserve 13)
 *           liquidBTC rate  2d -> 7d   (reserve 14)
 *           liquidUSD rate  2d -> 7d   (reserve 15)
 *
 *         WHY. The bound being changed is on the Veda RATE leg, which bounds the age of the
 *         accountant's `lastUpdateTimestamp` — i.e. the KEEPER's publication clock, not a market
 *         aggregator's. Measured over the accountants' full 137-day history, that keeper produces
 *         multi-day gaps: the liquidETH/liquidBTC accountants went 44.64h between updates on
 *         2026-08-18 22:27 -> 2026-08-20 19:05, which is 3.36h of headroom on a 48h bound, and the
 *         liquidETH accountant's worst-ever gap is 96.76h (2026-05-04 -> 2026-05-08). At 7 days the
 *         worst observed gap across all four leaves 71.2h of headroom and there are ZERO breaches in
 *         the full history. The instance has only been live since 2026-07-30 21:59 (block 154924987),
 *         so it has not yet seen the worst of that distribution.
 *
 *         THIS IS THE OPPOSITE DIRECTION FROM 644, AND DELIBERATELY SO. 644 relaxed MARKET
 *         aggregator legs. This relaxes KEEPER legs. Those are two independent clocks and must be
 *         sized separately: no amount of keeper diligence makes a market publish on a weekend, and
 *         no market cadence bounds when Veda chooses to run its accountant.
 *
 *         WHAT IT COSTS, SIZED. A frozen rate held the extra 5 days mis-prices collateral by, at the
 *         drift rates observed since the instance went live, 4.6 bps (liquidETH, 0.91 bps/day max),
 *         2.2 bps (liquidBTC, 0.44), 7.3 bps (liquidUSD, 1.46). Single-digit bps. Against that: a
 *         breach today freezes withdrawal of the affected holders' ENTIRE position, because
 *         `Spoke._processUserAccountData` prices every reserve in a user's position map with no
 *         try/catch. Debt is currently zero on all four reserves, so there is no bad-debt path — the
 *         exposure is a liveness freeze on roughly $65M of collateral.
 *
 *         WHY A REDEPLOY AND NOT A SETTER. Same two immutables as 644, one layer down.
 *         `VedaAccountantPriceFeed.rateMaxStaleness` is immutable, and `RATIO_PROVIDER` is immutable
 *         on Aave's `PriceCapAdapterBase` — and the cap setters are permanently unreachable on this
 *         instance by design (the ACL manager is the AccessManager, which implements neither
 *         `isRiskAdmin` nor `isPoolAdmin`). So a new bound means a new rate leg, and a new rate leg
 *         means the adapter above it is rebuilt too. Two contracts per reserve, eight in total.
 *
 *         THE BASE LEGS ARE NOT TOUCHED. Each rebuilt adapter reuses the SAME
 *         `BASE_TO_USD_AGGREGATOR` it reads today. Those legs are already well provisioned: the
 *         ETH/USD and BTC/USD aggregators under reserves 13/14 publish with a measured max gap of
 *         0.34h against a 48h bound, and USDC/USD under reserve 15 runs a 24.01h heartbeat against
 *         48h. Rebuilding them would also hit reserves 5 (weETH) and 6 (eBTC), which are out of
 *         scope here. Reserve 9's base is the ETHFI/USD 36h leg that 644 installed.
 *
 *         NOTE ON THE COMPOSED BUDGET. A cap adapter's price is base x ratio, and each leg enforces
 *         its own bound, so the worst-case age of a served composed price is the SUM: after this
 *         change, 48h + 7d = 9 days for reserves 13/14/15, and 36h + 7d for reserve 9. The keeper
 *         clock (7d) is the binding one for operational alarms; the base contributes ~0.34h in
 *         practice on the ETH and BTC legs.
 *
 *         NOTHING ELSE CHANGES. Each rebuilt adapter reuses the same base leg and the same
 *         accountant, and carries the same growth-cap snapshot forward, read off the live adapter
 *         rather than restated as a constant. `_verify` asserts every new source prices EXACTLY
 *         equal to the live one — not within a tolerance — because with the same base, the same
 *         accountant and the same snapshot there is no legitimate reason for a single wei of drift.
 *
 *         OUT OF SCOPE, ON PURPOSE. Reserves 16 (liquidRESERVE) and 18 (liquidRWA) are ALREADY at
 *         7 days and must stay there: their Midas push feeds show max gaps of 143.59h and 148.78h,
 *         so a 5-day bound would have breached and 7 days is correct. Reserve 7 (eUSD) shares the
 *         48h Veda bound but has zero supply, so it is left for a later batch rather than spending
 *         two deploys on a dormant reserve. Reserve 6 (eBTC) also shares the bound and its
 *         worst-ever gap is 624.04h; it holds only $223K and its own growth cap is deliberately
 *         loose, so it is called out in the 3CP for a follow-up rather than bundled here.
 *
 *         This script never repoints a reserve. `updateReservePriceSource` sits on the configurator
 *         domain-admin role (400, Owner Safe only), so the swap is an Owner Safe batch — written to
 *         output/3CP-657-RelaxVedaRateStaleness-10.json for the Safe Transaction Builder.
 *
 * Usage — dry run first (no --broadcast), which still runs every assertion:
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RelaxVedaRateStalenessBounds.s.sol:RelaxVedaRateStalenessBounds \
 *     --rpc-url $OPTIMISM_RPC --sender <deployer address> -vvv
 *
 * Then broadcast and verify:
 *   source .env && FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RelaxVedaRateStalenessBounds.s.sol:RelaxVedaRateStalenessBounds \
 *     --rpc-url $OPTIMISM_RPC --account etherfi-deployer --sender <deployer address> \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 */
contract RelaxVedaRateStalenessBounds is Script {
    // ---------------------------------------------------------------- instance (OP Mainnet)
    address constant ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
    address constant SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    address constant SPOKE_CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    address constant OWNER_SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;

    // ---------------------------------------------------------------- Veda accountants
    // Each new rate leg must read exactly these — the same accountants the live rate legs read.
    address constant SETHFI_ACCOUNTANT = 0x05A1552c5e18F5A0BB9571b5F2D6a4765ebdA32b; // 18 dec
    address constant LIQUID_ETH_ACCOUNTANT = 0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198; // 18 dec
    address constant LIQUID_BTC_ACCOUNTANT = 0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0; //  8 dec
    address constant LIQUID_USD_ACCOUNTANT = 0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7; //  6 dec

    // ---------------------------------------------------------------- live sources being replaced
    // Read back from the oracle in _verify too; these constants exist so a source that has already
    // moved fails the run instead of being silently rebuilt from something unexpected.
    address constant LIVE_SETHFI_ADAPTER = 0xd452ca984E0606297bCb430e076087F126e24a38;
    address constant LIVE_LIQUID_ETH_ADAPTER = 0x48420d702a3190235B5A5D123ca82f876752add1;
    address constant LIVE_LIQUID_BTC_ADAPTER = 0xD60ec8fCba09c7642099eA89A9D58721B00277C7;
    address constant LIVE_LIQUID_USD_ADAPTER = 0x17DdE04d8Ff1024D3076944658ED9B6bd5F51451;

    // The live rate legs, each of which carries the 2-day bound this change replaces.
    address constant LIVE_SETHFI_RATE = 0xb1F53B6aA18205bb8E468EC6a8cF3b8194ed5d7E;
    address constant LIVE_LIQUID_ETH_RATE = 0x1305D82Ce705b4E73bF22E5548c6cF90bA1735Db;
    address constant LIVE_LIQUID_BTC_RATE = 0x60BE06699ABe614E0FbA99eC11a1CDa6B2238755;
    address constant LIVE_LIQUID_USD_RATE = 0x0C5631727ECF13f3e726Bc3301E364Af51b69295;

    // ---------------------------------------------------------------- staleness bounds
    uint256 constant OLD_VEDA_RATE = 2 days;
    uint256 constant NEW_VEDA_RATE = 7 days;

    /// @dev Precision of the Veda RATE leg. Must match the live legs, whose `RATIO_DECIMALS` the
    ///      rebuilt adapters are asserted to preserve — and must match the units the carried
    ///      snapshot ratios are expressed in. See DeployCapoPriceAdapters.VEDA_RATE_DECIMALS for why
    ///      18 rather than the accountants' native precision: `maxRatioGrowthPerSecondScaled` floors
    ///      to zero below 317, and at 8 decimals these legs would sit ~1e10 closer to that floor.
    uint8 constant VEDA_RATE_DECIMALS = 18;

    uint8 constant USD_FEED_DECIMALS = 8;

    /// @dev Aave's `PriceCapAdapterBase` rejects a snapshot older than this, so a carried-forward
    ///      snapshot has a deploy deadline. Checked before every rebuild.
    uint48 constant MAX_SNAPSHOT_TERM = 180 days;

    // ---------------------------------------------------------------- expected cap parameters
    // The cap values risk signed off on at the CAPO rollout, read back off the live adapters on
    // 2026-08-20 and pinned here. The rebuild reads the LIVE values and passes them through, but it
    // also asserts they still equal these — so a re-snapshot that happened between review and deploy
    // fails the run instead of being silently carried into the new adapters.
    uint104 constant SNAP_SETHFI = 1_187_971_295_403_462_986;
    uint16 constant GROWTH_SETHFI = 1200; // 12.00%

    uint104 constant SNAP_LIQUID_ETH = 1_094_734_190_917_310_748;
    uint16 constant GROWTH_LIQUID_ETH = 500; //  5.00%

    uint104 constant SNAP_LIQUID_BTC = 1_029_351_010_000_000_000;
    uint16 constant GROWTH_LIQUID_BTC = 300; //  3.00%

    uint104 constant SNAP_LIQUID_USD = 1_160_589_000_000_000_000;
    uint16 constant GROWTH_LIQUID_USD = 750; //  7.50%

    /// @dev All four adapters share the CAPO rollout snapshot timestamp.
    uint48 constant SNAPSHOT_TS_VEDA = 1_780_627_963;

    // ---------------------------------------------------------------- reserve ids
    uint256 constant RESERVE_SETHFI = 9;
    uint256 constant RESERVE_LIQUID_ETH = 13;
    uint256 constant RESERVE_LIQUID_BTC = 14;
    uint256 constant RESERVE_LIQUID_USD = 15;

    struct Result {
        string symbol;
        uint256 reserveId;
        address newSource;
        address replaces;
        uint256 price;
    }

    Result[] internal results;

    /// @dev The fork's real timestamp, captured once at the very start of `run()` before anything
    ///      warps the clock. `_proveBoundMoved` warps repeatedly, and forge re-executes `run()` for
    ///      its on-chain simulation pass, so re-reading `block.timestamp` inside that helper can pick
    ///      up a timestamp left over from a previous warp and make the "is the rate already stale"
    ///      guard fire spuriously. Capture once, reset to this.
    uint256 internal forkTimestamp;

    function run() public {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        require(ACCESS_MANAGER.code.length != 0, "no code at the AccessManager");

        forkTimestamp = block.timestamp;
        vm.startBroadcast();

        _record(
            "sETHFI",
            _rebuild(LIVE_SETHFI_ADAPTER, LIVE_SETHFI_RATE, SETHFI_ACCOUNTANT, "sETHFI", SNAP_SETHFI, GROWTH_SETHFI),
            RESERVE_SETHFI
        );
        _record(
            "liquidETH",
            _rebuild(LIVE_LIQUID_ETH_ADAPTER, LIVE_LIQUID_ETH_RATE, LIQUID_ETH_ACCOUNTANT, "liquidETH", SNAP_LIQUID_ETH, GROWTH_LIQUID_ETH),
            RESERVE_LIQUID_ETH
        );
        _record(
            "liquidBTC",
            _rebuild(LIVE_LIQUID_BTC_ADAPTER, LIVE_LIQUID_BTC_RATE, LIQUID_BTC_ACCOUNTANT, "liquidBTC", SNAP_LIQUID_BTC, GROWTH_LIQUID_BTC),
            RESERVE_LIQUID_BTC
        );
        _record(
            "liquidUSD",
            _rebuild(LIVE_LIQUID_USD_ADAPTER, LIVE_LIQUID_USD_RATE, LIQUID_USD_ACCOUNTANT, "liquidUSD", SNAP_LIQUID_USD, GROWTH_LIQUID_USD),
            RESERVE_LIQUID_USD
        );

        vm.stopBroadcast();

        _verify();
        _rehearse();
        _printSafeBatch();
        _writeSafeBatchJson();
        _writeJson();
    }

    // ------------------------------------------------------------------ rate legs

    /// @dev Deploys the replacement for a live `VedaAccountantPriceFeed`, asserting first that the
    ///      live one is what we think it is: same accountant, same precision, and the exact bound we
    ///      are claiming to change. The description is carried over verbatim so the new leg is
    ///      indistinguishable from the old one in any explorer or dashboard that keys on it.
    function _rateLeg(address liveRate, address accountant, string memory symbol) internal returns (address) {
        VedaAccountantPriceFeed live = VedaAccountantPriceFeed(liveRate);
        require(address(live.accountant()) == accountant, string.concat(symbol, ": live rate leg reads a different accountant"));
        require(live.rateMaxStaleness() == OLD_VEDA_RATE, string.concat(symbol, ": live rate bound is not the one this run assumes"));
        require(!live.isStableToken(), string.concat(symbol, ": live rate leg snaps to $1, the replacement would not match"));
        require(live.decimals() == VEDA_RATE_DECIMALS, string.concat(symbol, ": live rate leg precision is not the assumed one"));
        require(address(live.underlyingUsdFeed()) == address(0), string.concat(symbol, ": live rate leg composes an underlying, this rebuild would drop it"));

        VedaAccountantPriceFeed fresh = new VedaAccountantPriceFeed(
            IVedaAccountant(accountant),
            IAaveV4PriceFeed(address(0)),
            VEDA_RATE_DECIMALS,
            NEW_VEDA_RATE,
            false,
            live.description()
        );

        require(fresh.rateMaxStaleness() == NEW_VEDA_RATE, string.concat(symbol, ": new rate bound did not take"));
        require(fresh.rateMaxStaleness() > live.rateMaxStaleness(), string.concat(symbol, ": new rate bound is not looser, nothing to change"));
        require(address(fresh.accountant()) == accountant, string.concat(symbol, ": new rate leg reads the wrong accountant"));
        require(fresh.decimals() == VEDA_RATE_DECIMALS, string.concat(symbol, ": new rate leg precision changed"));

        // Same accountant, same block, same precision: the rate must match to the wei.
        int256 liveRateAnswer = live.latestAnswer();
        int256 freshRateAnswer = fresh.latestAnswer();
        require(liveRateAnswer > 0, string.concat(symbol, ": live rate leg returned a non-positive rate"));
        require(
            freshRateAnswer == liveRateAnswer,
            string.concat(symbol, ": rebuilt rate leg differs - live=", vm.toString(liveRateAnswer), " new=", vm.toString(freshRateAnswer))
        );

        console.log(string.concat("  rate leg ", symbol, "  ", vm.toString(address(fresh)), "  bound=", vm.toString(NEW_VEDA_RATE), "s"));
        return address(fresh);
    }

    // ------------------------------------------------------------------ adapter rebuilds

    /// @dev Rebuilds a `CLRatePriceCapAdapter` with a new RATE leg and everything else carried over
    ///      from the live adapter: base aggregator, description, minimum snapshot delay, and the full
    ///      cap snapshot. Nothing is restated as a constant, so nothing can drift from what is live.
    ///
    ///      `RATIO_DECIMALS` needs no explicit handling — `CLRatePriceCapAdapter` derives it from the
    ///      rate leg's `decimals()` — but it IS asserted equal to the live adapter's afterwards,
    ///      because a precision change there would silently rescale the carried snapshot and move the
    ///      cap without touching a single cap parameter.
    function _rebuild(
        address liveAdapter,
        address liveRate,
        address accountant,
        string memory symbol,
        uint104 expectedRatio,
        uint16 expectedGrowth
    ) internal returns (address) {
        IPriceCapAdapter live = IPriceCapAdapter(liveAdapter);

        // The rate leg on the live adapter must be the one we are replacing, not something else.
        require(live.RATIO_PROVIDER() == liveRate, string.concat(symbol, ": live adapter reads a different rate leg than this run assumes"));

        address baseAggregator = address(live.BASE_TO_USD_AGGREGATOR());
        require(baseAggregator.code.length != 0, string.concat(symbol, ": live base leg has no code"));

        uint256 snapshotRatio = live.getSnapshotRatio();
        uint256 snapshotTs = live.getSnapshotTimestamp();
        uint256 growthPercent = live.getMaxYearlyGrowthRatePercent();
        uint48 minDelay = live.MINIMUM_SNAPSHOT_DELAY();

        // The live cap must still be the one risk signed off on. If it has been re-snapshotted since
        // this change was written, stop — carrying an unreviewed cap forward is not this script's call.
        require(snapshotRatio == expectedRatio, string.concat(symbol, ": live snapshot ratio is not the reviewed value"));
        require(snapshotTs == SNAPSHOT_TS_VEDA, string.concat(symbol, ": live snapshot timestamp is not the reviewed value"));
        require(growthPercent == expectedGrowth, string.concat(symbol, ": live growth percent is not the reviewed value"));

        // Aave's `_setCapParameters` window. Failing here means the carried snapshot has aged out and
        // a fresh one must be taken and risk-reviewed — do NOT paper over it by loosening the growth.
        require(snapshotTs + minDelay <= block.timestamp, string.concat(symbol, ": carried snapshot is newer than MINIMUM_SNAPSHOT_DELAY"));
        require(snapshotTs + MAX_SNAPSHOT_TERM > block.timestamp, string.concat(symbol, ": carried snapshot is older than 180 days, re-snapshot required"));
        require(snapshotRatio <= type(uint104).max, string.concat(symbol, ": snapshot ratio overflows uint104"));
        require(growthPercent <= type(uint16).max, string.concat(symbol, ": growth percent overflows uint16"));

        // Deploy the new rate leg only after the cap preconditions hold, so a failed run does not
        // leave an orphan leg on chain.
        address newRate = _rateLeg(liveRate, accountant, symbol);

        address rebuilt = address(
            new CLRatePriceCapAdapter(
                IPriceCapAdapter.CapAdapterParams({
                    aclManager: IACLManager(ACCESS_MANAGER),
                    baseAggregatorAddress: baseAggregator,
                    ratioProviderAddress: newRate,
                    pairDescription: live.description(),
                    minimumSnapshotDelay: minDelay,
                    priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
                        snapshotRatio: uint104(snapshotRatio),
                        snapshotTimestamp: SNAPSHOT_TS_VEDA,
                        maxYearlyRatioGrowthPercent: uint16(growthPercent)
                    })
                })
            )
        );

        // The cap must be a clone, not a re-tune. Compare every parameter that shapes the ceiling.
        IPriceCapAdapter fresh = IPriceCapAdapter(rebuilt);
        require(address(fresh.BASE_TO_USD_AGGREGATOR()) == baseAggregator, string.concat(symbol, ": base aggregator changed"));
        require(fresh.RATIO_PROVIDER() == newRate, string.concat(symbol, ": rate leg did not take"));
        require(fresh.RATIO_PROVIDER() != liveRate, string.concat(symbol, ": adapter still reads the old rate leg"));
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

    /// @dev Exact equality, not a tolerance. Same base aggregator, same accountant, same snapshot,
    ///      same block: any difference at all is a wiring bug.
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
    // Execute the change in the OWNER SAFE'S OWN CONTEXT against the real instance and real roles,
    // verify the resulting state field by field, and share that verifier with the post-execution
    // check. Pranking as the Owner Safe bypasses the Safe's signature threshold but NOT the
    // configurator's role check, so this is a genuine test that the Safe holds role 400 — a missing
    // role fails here rather than after the signers have already collected signatures.

    struct Expect {
        uint256 reserveId;
        string symbol;
        address accountant; // the Veda accountant the rate leg must read
        uint104 snapRatio;
        uint16 growth;
    }

    function _expectations() internal pure returns (Expect[4] memory e) {
        e[0] = Expect(RESERVE_SETHFI, "sETHFI", SETHFI_ACCOUNTANT, SNAP_SETHFI, GROWTH_SETHFI);
        e[1] = Expect(RESERVE_LIQUID_ETH, "liquidETH", LIQUID_ETH_ACCOUNTANT, SNAP_LIQUID_ETH, GROWTH_LIQUID_ETH);
        e[2] = Expect(RESERVE_LIQUID_BTC, "liquidBTC", LIQUID_BTC_ACCOUNTANT, SNAP_LIQUID_BTC, GROWTH_LIQUID_BTC);
        e[3] = Expect(RESERVE_LIQUID_USD, "liquidUSD", LIQUID_USD_ACCOUNTANT, SNAP_LIQUID_USD, GROWTH_LIQUID_USD);
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

        // The whole point of the change: prove the relaxed bound actually buys the extra window, and
        // prove the OLD bound would have failed in it. Both directions, on the same fork.
        _proveBoundMoved();

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

    /// @dev Non-vacuity for the bound itself. Warping time is the only way to show a staleness change
    ///      did anything, and it has to be shown in BOTH directions or the test proves nothing:
    ///
    ///        - at 3 days stale the NEW source still prices, and the OLD one reverts. That is the
    ///          window this change buys, and the proof it was actually closed before.
    ///        - at exactly 7 days the NEW source still prices. `latestAnswer` compares with a strict
    ///          `>`, so an off-by-one here would be invisible from the "eventually reverts" side.
    ///        - at 7 days + 1 second the NEW source reverts too, proving the new bound is a real
    ///          bound and not simply removed.
    ///
    ///      ISOLATING THE CLOCK UNDER TEST. A cap adapter's price is base x rate and each leg
    ///      enforces its own bound, so a naive `vm.warp` past 48h trips the BASE leg first and every
    ///      assertion below would pass for the wrong reason — the classic frozen-fork-timestamp trap.
    ///      The base leg's `latestAnswer()` is therefore mocked to the value it returns right now, so
    ///      the only clock still running is the Veda rate clock this change actually moves. The base
    ///      clock is a separate bound, deliberately untouched by this batch, and is asserted non-zero
    ///      in `verifyLive` rather than exercised here.
    ///
    ///      THE BOUNDARY IS MEASURED FROM THE ACCOUNTANT, NOT FROM NOW. `VedaAccountantPriceFeed`
    ///      compares `block.timestamp > state.lastUpdateTimestamp + rateMaxStaleness`, so the edge
    ///      sits at the ACCOUNTANT's last update plus the bound. Warping to `now + 7 days` overshoots
    ///      it by however stale the rate already is on the fork, which reads as a spurious failure at
    ///      the "exactly at the bound" case. Each reserve's edge is therefore derived from its own
    ///      accountant, since the four do not have to update in lockstep.
    function _proveBoundMoved() internal {
        uint256 t = forkTimestamp;
        require(t > 0, "fork timestamp was never captured");
        vm.warp(t);
        // Freeze the base leg so only the rate clock advances. Mocked per adapter, using each one's
        // own live base price, so the composed price stays exactly what it is today.
        for (uint256 i; i < results.length; i++) {
            address baseLeg = address(IPriceCapAdapter(results[i].newSource).BASE_TO_USD_AGGREGATOR());
            int256 basePrice = ICLSynchronicityPriceAdapter(baseLeg).latestAnswer();
            require(basePrice > 0, string.concat(results[i].symbol, ": base leg is not pricing, cannot isolate the rate clock"));
            vm.mockCall(baseLeg, abi.encodeCall(ICLSynchronicityPriceAdapter.latestAnswer, ()), abi.encode(basePrice));
        }

        for (uint256 i; i < results.length; i++) {
            Result storage r = results[i];

            // Each iteration warps time around, so reset to the fork's real clock before reading the
            // next reserve's boundary — otherwise the guard below is evaluated against a timestamp
            // left over from the previous reserve.
            vm.warp(t);

            // The rate's own clock: the accountant's last update, read through the new rate leg.
            VedaAccountantPriceFeed rateLeg = VedaAccountantPriceFeed(IPriceCapAdapter(r.newSource).RATIO_PROVIDER());
            uint256 lastUpdate = rateLeg.accountant().accountantState().lastUpdateTimestamp;
            require(lastUpdate > 0, string.concat(r.symbol, ": accountant has never updated, the boundary would be meaningless"));
            require(lastUpdate + OLD_VEDA_RATE > t, string.concat(r.symbol, ": rate is ALREADY past the old bound on this fork, the old-source control would be vacuous"));

            // ---- 3 days old: inside the new 7-day bound, outside the old 2-day one
            vm.warp(lastUpdate + 3 days);
            require(
                IAaveOracleLike(AAVE_ORACLE).getReservePrice(r.reserveId) > 0,
                string.concat(r.symbol, ": new source does not survive a 3-day-old rate, the change bought nothing")
            );
            // The old adapter must fail here, and it must fail by REVERTING: its rate leg reverts
            // `StalePrice`, which propagates through Aave's adapter rather than being swallowed into
            // the `return 0` branch. A zero return would be a different (and worse) failure mode.
            require(
                _reverts(r.replaces),
                string.concat(r.symbol, ": the OLD source also survives 3 days - the 2-day bound was not binding, so this run is not the fix")
            );

            // ---- exactly at the new bound: must still price (the comparison is a strict `>`)
            vm.warp(lastUpdate + NEW_VEDA_RATE);
            require(
                IAaveOracleLike(AAVE_ORACLE).getReservePrice(r.reserveId) > 0,
                string.concat(r.symbol, ": new source reverts exactly AT the bound, off by one")
            );

            // ---- one second past it: must fail closed
            vm.warp(lastUpdate + NEW_VEDA_RATE + 1);
            require(
                _revertsOracle(r.reserveId),
                string.concat(r.symbol, ": new source still prices past the bound - the bound is not enforced")
            );

            console.log(
                string.concat(
                    "  ", r.symbol, ": prices at 3d and at exactly 7d, reverts at 7d+1s, old 2d source reverts at 3d",
                    "  (accountant last update ", vm.toString(lastUpdate), ")"
                )
            );
        }

        vm.warp(t);
        vm.clearMockedCalls();

        // Prove the mock is gone: the sources must price again off the real base legs, at exactly the
        // value verified before the warping started.
        for (uint256 i; i < results.length; i++) {
            require(
                IAaveOracleLike(AAVE_ORACLE).getReservePrice(results[i].reserveId) == results[i].price,
                string.concat(results[i].symbol, ": price did not return to the real value after clearing the base-leg mock")
            );
        }
    }

    function _reverts(address source) internal view returns (bool) {
        (bool ok,) = source.staticcall(abi.encodeCall(ICLSynchronicityPriceAdapter.latestAnswer, ()));
        return !ok;
    }

    function _revertsOracle(uint256 reserveId) internal view returns (bool) {
        (bool ok,) = AAVE_ORACLE.staticcall(abi.encodeCall(IAaveOracleLike.getReservePrice, (reserveId)));
        return !ok;
    }

    /**
     * @notice Field-by-field check that the live instance reads the relaxed sources with the reviewed
     *         cap parameters intact. Shared by the dress rehearsal above and runnable standalone
     *         AFTER the Owner Safe executes the batch:
     *
     *           source .env && FOUNDRY_PROFILE=aave-deploy forge script \
     *             scripts/aave-v4/RelaxVedaRateStalenessBounds.s.sol:RelaxVedaRateStalenessBounds \
     *             --sig 'verifyLive()' --rpc-url $OPTIMISM_RPC -v
     *
     * @dev Asserts PROPERTIES, never deployed addresses, so it works without being told what was
     *      deployed — and so it cannot be satisfied by a source that merely happens to sit at the
     *      expected address. Returns the number of reserves checked so a silent zero-iteration pass
     *      cannot read as success.
     */
    function verifyLive() public view returns (uint256 checked) {
        require(block.chainid == 10, "run on OP Mainnet (10)");
        Expect[4] memory expects = _expectations();

        for (uint256 i; i < expects.length; i++) {
            Expect memory e = expects[i];
            address src = IAaveOracleLike(AAVE_ORACLE).getReserveSource(e.reserveId);
            require(src.code.length != 0, string.concat(e.symbol, ": live source has no code"));
            require(ICLSynchronicityPriceAdapter(src).decimals() == USD_FEED_DECIMALS, string.concat(e.symbol, ": live source decimals != 8"));
            require(IAaveOracleLike(AAVE_ORACLE).getReservePrice(e.reserveId) > 0, string.concat(e.symbol, ": live reserve price is not positive"));

            IPriceCapAdapter cap = IPriceCapAdapter(src);
            require(cap.getSnapshotRatio() == e.snapRatio, string.concat(e.symbol, ": snapshot ratio is not the reviewed value"));
            require(cap.getSnapshotTimestamp() == SNAPSHOT_TS_VEDA, string.concat(e.symbol, ": snapshot timestamp is not the reviewed value"));
            require(cap.getMaxYearlyGrowthRatePercent() == e.growth, string.concat(e.symbol, ": growth percent is not the reviewed value"));
            require(cap.getMaxRatioGrowthPerSecondScaled() > 0, string.concat(e.symbol, ": growth floored to zero"));
            require(!cap.isCapped(), string.concat(e.symbol, ": growth cap is binding, collateral is under-priced"));

            // The point of the whole change: the rate leg reads the same accountant as before and
            // now carries the relaxed bound.
            VedaAccountantPriceFeed rateLeg = VedaAccountantPriceFeed(cap.RATIO_PROVIDER());
            require(address(rateLeg.accountant()) == e.accountant, string.concat(e.symbol, ": rate leg reads the wrong accountant"));
            require(rateLeg.rateMaxStaleness() == NEW_VEDA_RATE, string.concat(e.symbol, ": rate leg bound is not the relaxed value"));
            require(rateLeg.decimals() == VEDA_RATE_DECIMALS, string.concat(e.symbol, ": rate leg precision changed"));
            require(cap.RATIO_DECIMALS() == VEDA_RATE_DECIMALS, string.concat(e.symbol, ": adapter ratio decimals do not match the rate leg"));

            // The base leg is explicitly NOT part of this change; assert it still enforces a bound so
            // a future run cannot quietly leave the composed price unbounded on the base side.
            address baseLeg = address(cap.BASE_TO_USD_AGGREGATOR());
            require(ChainlinkPriceFeed(baseLeg).rateMaxStaleness() > 0, string.concat(e.symbol, ": base leg has no staleness bound"));

            console.log(string.concat("  verified ", e.symbol, "  reserve=", vm.toString(e.reserveId), "  rate bound=", vm.toString(NEW_VEDA_RATE), "s"));
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
    ///      into `queued/657/optimism.json` with no reshaping. Matches 3CP-616 and 3CP-644 field for
    ///      field — the same Safe, the same target and the same `updateReservePriceSource` selector —
    ///      which is what the hash generation workflow and the offline signers consume.
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
        vm.writeFile("output/3CP-657-RelaxVedaRateStaleness-10.json", json);
        console.log("");
        console.log("wrote output/3CP-657-RelaxVedaRateStaleness-10.json  (drop-in for 3CP-Secure queued/657/optimism.json)");
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
        vm.writeFile("output/RelaxedVedaRateFeedsOP.json", json);
        console.log("wrote output/RelaxedVedaRateFeedsOP.json");
    }
}
