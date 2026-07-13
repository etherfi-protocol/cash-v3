// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAccessManager } from "aave-v4/dependencies/openzeppelin/IAccessManager.sol";
import { AssetInterestRateStrategy } from "aave-v4/hub/AssetInterestRateStrategy.sol";
import { IAssetInterestRateStrategy } from "aave-v4/hub/interfaces/IAssetInterestRateStrategy.sol";
import { IHub } from "aave-v4/hub/interfaces/IHub.sol";
import { Roles } from "aave-v4/libraries/types/Roles.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { IVedaAccountant } from "../../src/interfaces/IVedaAccountant.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { IPythPairOracle, PythPriceFeed } from "../../src/oracle/PythPriceFeed.sol";
import { VedaAccountantPriceFeed } from "../../src/oracle/VedaAccountantPriceFeed.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title AddSummerLendCollateral
 * @notice Lists the Summer Lend collateral set on the Aave v4 TEST instance (spoke/hub from
 *         deployments/<env>/10/aave-v4-test.json), collateral-only (borrowable = false), with the
 *         collateral factors and liquidation bonuses the DebtManager uses today (Notion:
 *         "ether.fi Summer Lend" — QQQ/SPY/PAXG excluded; USDC/weETH already listed at deploy).
 *
 *         Price sources per asset class — every leg is an IAaveV4PriceFeed, so feeds compose:
 *         - One staleness-checked ChainlinkPriceFeed per Chainlink oracle (ETH/BTC/USDC/USDT/EUR/
 *           OP / USD), shared as direct reserve sources (USDT, WETH, OP, frxUSD at USDC/USD) and
 *           as underlying legs.
 *         - Pyth per-pair oracles (16-dec `price()`) via PythPriceFeed: ETHFI, wHYPE, beHYPE, EURC.
 *         - Veda receipt tokens via VedaAccountantPriceFeed (accountant discovered on-chain from
 *           the teller) x an underlying feed: liquidETH/liquidBTC/liquidUSD/eBTC/eUSD over the
 *           Chainlink feeds, and sETHFI (rate in ETHFI) over the ETHFI/USD PythPriceFeed.
 *         - Midas receipt tokens as ChainlinkPriceFeeds in composed mode over their 8-dec
 *           latestRoundData proxies: weEUR (weEUR/EUR x EUR/USD), liquidRESERVE and liquidRWA
 *           (x USDC/USD $1 leg).
 *
 *         Idempotent: assets whose underlying is already a listed reserve are skipped, so the
 *         script can be re-run after a partial broadcast.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must hold the instance admin roles):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/AddSummerLendCollateral.s.sol:AddSummerLendCollateral \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract AddSummerLendCollateral is Utils {
    // --- tokens (OP) ---
    address constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant FRXUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant LIQUID_ETH = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant EBTC = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant EUSD = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address constant WHYPE = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address constant ETHFI = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant BEHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address constant LIQUID_RESERVE = 0xE5d3854736e0D513aAE2D8D708Ad94d14Fd56A6a;
    address constant WEEUR = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;
    address constant OP = 0x4200000000000000000000000000000000000042;

    // --- Chainlink oracles (OP) ---
    address constant WEETH_ETH_ORACLE = 0xb4479d436DDa5c1A79bD88D282725615202406E3; // weETH / ETH exchange rate
    address constant ETH_USD = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address constant USDC_USD = 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3;
    address constant USDT_USD = 0xECef79E109e997bCA29c1c0897ec9d7b03647F5E;
    address constant BTC_USD = 0xD702DD976Fb76Fffc2D3963D037dfDae5b04E593;
    address constant EUR_USD = 0x3626369857A10CcC6cc3A6e4f5C2f5984a519F20;
    address constant OP_USD = 0x0D276FC14719f9292D5C1eA2198673d1f4269246;

    // --- Pyth per-pair oracles (OP, 16-dec price(); see scripts/gnosis-txs/SetPythOraclesOP.s.sol) ---
    uint8 constant PYTH_ORACLE_DECIMALS = 16;
    address constant ETHFI_USD_PYTH = 0x3E377b4e02bc848Ade3c289477F21441b7e014C2;
    address constant WHYPE_USD_PYTH = 0x1f860581483253B81ECB0E89b2b978A202de553d;
    address constant BEHYPE_USD_PYTH = 0x2ACd77fefED51Fa80FBF1520701c73Ac506D4381;
    address constant EURC_USD_PYTH = 0x62779cdAadd1eB782eb4fF534739B55763A48385;

    // --- Veda tellers (OP; accountant discovered via teller.accountant()) ---
    address constant SETHFI_TELLER = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;
    address constant LIQUID_ETH_TELLER = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant LIQUID_USD_TELLER = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant EBTC_TELLER = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;
    address constant EUSD_TELLER = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;

    // --- Midas 8-dec latestRoundData proxies (OP; from the dev PriceProviderV2 configs) ---
    address constant LIQUID_RESERVE_USD_PROXY = 0x58dDf77A329CcbE2F4C2114C64ed9E12Ec8a1356; // liquidRESERVE/USD
    address constant WEEUR_EUR_PROXY = 0x01b910C1aa51cdC4a2a84d76CB255C4974Bf8A19; // weEUR/EUR
    address constant LIQUID_RWA_USD_PROXY = 0xd5aaE6ac1a9ed4BE5DcC1fc172EDeFFd5B6d8080; // liquidRWA/USD

    uint8 constant FEED_DECIMALS = 8;
    uint256 constant CHAINLINK_MAX_STALENESS = 1 days;
    uint256 constant VEDA_RATE_MAX_STALENESS = 2 days;
    // The Midas proxies update roughly weekly (the PriceProvider config allows 7 days)
    uint256 constant MIDAS_RATE_MAX_STALENESS = 7 days;

    IHub hub;
    ISpoke spoke;
    AssetInterestRateStrategy irStrategy;
    address treasurySpoke;
    IAccessManager accessManager;
    uint256 weethReserveId;
    uint256 usdcReserveId;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy");

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json"));
        hub = IHub(stdJson.readAddress(json, ".hub"));
        spoke = ISpoke(stdJson.readAddress(json, ".spoke"));
        irStrategy = AssetInterestRateStrategy(stdJson.readAddress(json, ".irStrategy"));
        treasurySpoke = stdJson.readAddress(json, ".treasurySpoke");
        accessManager = IAccessManager(stdJson.readAddress(json, ".accessManager"));
        weethReserveId = stdJson.readUint(json, ".weethReserveId");
        usdcReserveId = stdJson.readUint(json, ".usdcReserveId");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // One staleness-checked ChainlinkPriceFeed per Chainlink oracle, shared as direct sources
        // and as underlying legs
        address ethUsd = _chainlink(ETH_USD, address(0), CHAINLINK_MAX_STALENESS, "ETH / USD");
        address btcUsd = _chainlink(BTC_USD, address(0), CHAINLINK_MAX_STALENESS, "BTC / USD");
        address usdcUsd = _chainlink(USDC_USD, address(0), CHAINLINK_MAX_STALENESS, "USDC / USD");
        address usdtUsd = _chainlink(USDT_USD, address(0), CHAINLINK_MAX_STALENESS, "USDT / USD");
        address eurUsd = _chainlink(EUR_USD, address(0), CHAINLINK_MAX_STALENESS, "EUR / USD");
        address opUsd = _chainlink(OP_USD, address(0), CHAINLINK_MAX_STALENESS, "OP / USD");

        // Pyth-priced assets (ETHFI/USD is reused as sETHFI's underlying below)
        address ethfiUsd = _pyth(ETHFI_USD_PYTH, address(0), "ETHFI / USD");
        _list(ETHFI, ethfiUsd, 20_00, 10_500);
        _list(WHYPE, _pyth(WHYPE_USD_PYTH, address(0), "wHYPE / USD"), 45_00, 10_400);
        _list(BEHYPE, _pyth(BEHYPE_USD_PYTH, address(0), "beHYPE / USD"), 40_00, 10_500);
        _list(EURC, _pyth(EURC_USD_PYTH, address(0), "EURC / USD"), 90_00, 10_100);

        // Veda receipt tokens (accountant rate x underlying IAaveV4PriceFeed)
        _list(SETHFI, _veda(SETHFI_TELLER, ethfiUsd, "sETHFI / USD"), 20_00, 10_500); // rate is sETHFI/ETHFI
        _list(LIQUID_ETH, _veda(LIQUID_ETH_TELLER, ethUsd, "liquidETH / USD"), 50_00, 10_500);
        _list(LIQUID_BTC, _veda(LIQUID_BTC_TELLER, btcUsd, "liquidBTC / USD"), 50_00, 10_500);
        _list(LIQUID_USD, _veda(LIQUID_USD_TELLER, usdcUsd, "liquidUSD / USD"), 80_00, 10_200);
        _list(EBTC, _veda(EBTC_TELLER, btcUsd, "eBTC / USD"), 52_00, 10_500);
        _list(EUSD, _veda(EUSD_TELLER, usdcUsd, "eUSD / USD"), 80_00, 10_200);

        // Midas receipt tokens (proxy rate x composed USD leg)
        _list(LIQUID_RESERVE, _chainlink(LIQUID_RESERVE_USD_PROXY, usdcUsd, MIDAS_RATE_MAX_STALENESS, "liquidRESERVE / USD"), 80_00, 10_100);
        _list(WEEUR, _chainlink(WEEUR_EUR_PROXY, eurUsd, MIDAS_RATE_MAX_STALENESS, "weEUR / USD"), 70_00, 10_200);
        _list(LIQUID_RWA, _chainlink(LIQUID_RWA_USD_PROXY, usdcUsd, MIDAS_RATE_MAX_STALENESS, "liquidRWA / USD"), 70_00, 10_400);

        // Direct listings on the shared staleness-checked Chainlink feeds
        _list(USDT, usdtUsd, 90_00, 10_100);
        _list(WETH, ethUsd, 55_00, 10_350);
        _list(OP, opUsd, 20_00, 10_500);
        // frxUSD: $1-stable like the DebtManager treats it; USDC/USD is the closest live $1 feed
        _list(FRXUSD, usdcUsd, 90_00, 10_100);

        // Migrate the two deploy-time reserves onto the new staleness-checked feeds:
        // USDC was listed on the raw usdcUsdOracle aggregator, weETH on the pre-refactor composite.
        // updateReservePriceSource is `restricted`; its selector was not mapped at instance deploy.
        bytes4[] memory sourceSelectors = new bytes4[](1);
        sourceSelectors[0] = ISpoke.updateReservePriceSource.selector;
        accessManager.setTargetFunctionRole(address(spoke), sourceSelectors, Roles.SPOKE_ADMIN_ROLE);

        address weethUsd = _chainlink(WEETH_ETH_ORACLE, ethUsd, CHAINLINK_MAX_STALENESS, "weETH / USD");
        spoke.updateReservePriceSource(weethReserveId, weethUsd);
        console.log("updated weETH reserve price source:", weethUsd);
        spoke.updateReservePriceSource(usdcReserveId, usdcUsd);
        console.log("updated USDC reserve price source: ", usdcUsd);

        vm.stopBroadcast();

        _recordReserveIds(json);
        console.log("Done. Reserve count:", spoke.getReserveCount());
    }

    /// @dev Merges a symbol -> reserveId and symbol -> hub assetId map into aave-v4-test.json
    function _recordReserveIds(string memory existingJson) internal {
        uint256 count = spoke.getReserveCount();

        string memory reserveIds;
        string memory assetIds;
        for (uint256 i; i < count; ++i) {
            ISpoke.Reserve memory reserve = spoke.getReserve(i);
            string memory symbol = IERC20Metadata(reserve.underlying).symbol();
            reserveIds = vm.serializeUint("summer-lend-reserve-ids", symbol, i);
            assetIds = vm.serializeUint("summer-lend-asset-ids", symbol, reserve.assetId);
        }

        // Seed the serializer with the existing file so untouched keys survive the rewrite
        string memory root = "aave-v4-test-json";
        vm.serializeJson(root, existingJson);
        vm.serializeString(root, "reserveIds", reserveIds);
        string memory merged = vm.serializeString(root, "assetIds", assetIds);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json");
        vm.writeJson(merged, path);
        console.log("Recorded reserveIds + assetIds for", count, "reserves:", path);
    }

    /// @dev Deploys a ChainlinkPriceFeed over a Chainlink oracle, optionally composed on an underlying feed
    function _chainlink(address oracle, address underlyingUsdFeed, uint256 maxStaleness, string memory desc) internal returns (address) {
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(IAggregatorV3(oracle), IAaveV4PriceFeed(underlyingUsdFeed), FEED_DECIMALS, maxStaleness, desc);
        _requireLivePrice(address(feed), desc);
        return address(feed);
    }

    /// @dev Deploys a PythPriceFeed over a per-pair oracle, optionally composed on an underlying feed
    function _pyth(address pairOracle, address underlyingUsdFeed, string memory desc) internal returns (address) {
        PythPriceFeed feed = new PythPriceFeed(IPythPairOracle(pairOracle), PYTH_ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(underlyingUsdFeed), desc);
        _requireLivePrice(address(feed), desc);
        return address(feed);
    }

    /// @dev Deploys a VedaAccountantPriceFeed, resolving the accountant from the teller on-chain
    function _veda(address teller, address underlyingUsdFeed, string memory desc) internal returns (address) {
        IVedaAccountant accountant = IVedaAccountant(address(ILayerZeroTeller(teller).accountant()));
        VedaAccountantPriceFeed feed = new VedaAccountantPriceFeed(accountant, IAaveV4PriceFeed(underlyingUsdFeed), FEED_DECIMALS, VEDA_RATE_MAX_STALENESS, desc);
        _requireLivePrice(address(feed), desc);
        return address(feed);
    }

    function _requireLivePrice(address feed, string memory desc) internal view {
        int256 answer = IAaveV4PriceFeed(feed).latestAnswer();
        require(answer > 0, string.concat("dead feed: ", desc));
        // 8-decimal USD, printed as dollars.cents for a quick eyeball check
        uint256 cents = (uint256(answer) % 1e8) / 1e6;
        console.log(string.concat("  ", desc, ": $", vm.toString(uint256(answer) / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents)));
    }

    /// @dev Lists `token` as a collateral-only reserve, skipping tokens that are already listed
    function _list(address token, address priceSource, uint16 collateralFactorBps, uint32 maxLiquidationBonusBps) internal {
        if (_isListed(token)) {
            console.log("already listed, skipping:", IERC20Metadata(token).symbol(), token);
            return;
        }

        bytes memory irData = abi.encode(IAssetInterestRateStrategy.InterestRateData({ optimalUsageRatio: 9000, baseDrawnRate: 500, rateGrowthBeforeOptimal: 500, rateGrowthAfterOptimal: 500 }));

        uint256 assetId = hub.addAsset(token, IERC20Metadata(token).decimals(), treasurySpoke, address(irStrategy), irData);
        hub.updateAssetConfig(assetId, IHub.AssetConfig({ feeReceiver: treasurySpoke, liquidityFee: 1000, irStrategy: address(irStrategy), reinvestmentController: address(0) }), new bytes(0));

        uint256 reserveId = spoke.addReserve(address(hub), assetId, priceSource, ISpoke.ReserveConfig({ paused: false, frozen: false, borrowable: false, receiveSharesEnabled: true, collateralRisk: 0 }), ISpoke.DynamicReserveConfig({ collateralFactor: collateralFactorBps, maxLiquidationBonus: maxLiquidationBonusBps, liquidationFee: 1000 }));

        hub.addSpoke(assetId, address(spoke), IHub.SpokeConfig({ addCap: type(uint40).max, drawCap: type(uint40).max, riskPremiumThreshold: 100_000, active: true, halted: false }));

        console.log("listed:", IERC20Metadata(token).symbol(), reserveId);
        console.log("  feed:", priceSource);
    }

    function _isListed(address token) internal view returns (bool) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return true;
        }
        return false;
    }
}
