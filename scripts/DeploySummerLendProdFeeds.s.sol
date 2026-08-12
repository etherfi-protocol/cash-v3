// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { IVedaAccountant } from "../src/interfaces/IVedaAccountant.sol";
import { ChainlinkPriceFeed } from "../src/oracle/ChainlinkPriceFeed.sol";
import { IPythPairOracle, PythPriceFeed } from "../src/oracle/PythPriceFeed.sol";
import { VedaAccountantPriceFeed } from "../src/oracle/VedaAccountantPriceFeed.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeploySummerLendProdFeeds
 * @notice Deploys the Aave v4 price feeds for the Summer Lend prod instance on Optimism and writes
 *         their addresses to deployments/mainnet/10/summer-lend-feeds.json for the AIP payload.
 *         Deploy-only: the feeds are immutable and admin-less, and listing the reserves against
 *         them is the Aave governance payload's job, so no safe transaction is involved.
 *
 *         Every oracle address, staleness bound, and stable flag mirrors the live PriceProviderV2
 *         config (0x44dd2372FE7B97C4B4D6a7d4DeCf72466485BAcB, read on-chain 2026-07-23). Stocks
 *         (wSPYx) are not in the launch set.
 *
 * Usage (simulate by dropping --broadcast; the sender is the prod deployer Ledger, no key in env):
 *   source .env && ENV=mainnet forge script \
 *     scripts/DeploySummerLendProdFeeds.s.sol:DeploySummerLendProdFeeds \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeploySummerLendProdFeeds is Utils {
    using SafeCast for int256;

    // --- Chainlink-interface oracles (OP), from the live PriceProviderV2 config ---
    address constant ETH_USD_ORACLE = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address constant BTC_USD_ORACLE = 0xD702DD976Fb76Fffc2D3963D037dfDae5b04E593;
    address constant USDC_USD_ORACLE = 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3;
    address constant USDT_USD_ORACLE = 0xECef79E109e997bCA29c1c0897ec9d7b03647F5E;
    address constant FRXUSD_USD_ORACLE = 0x8BF42811876e1B692d0E70F61b80e1fbc68Ef1bf;
    address constant OP_USD_ORACLE = 0x0D276FC14719f9292D5C1eA2198673d1f4269246;
    address constant WEETH_ETH_ORACLE = 0xb4479d436DDa5c1A79bD88D282725615202406E3; // weETH/ETH exchange rate

    // --- Pyth per-pair oracles (OP, 16-dec price()). PriceProviderV2 points here today; the dev
    //     instance (AddSummerLendCollateral) uses a different, price-identical adapter set. ---
    uint8 constant PYTH_ORACLE_DECIMALS = 16;
    address constant ETHFI_USD_PYTH = 0x8A089Ae05073119C356130c2a7223608ff6737fd;
    address constant WHYPE_USD_PYTH = 0x370F16a9D36CDBe3f364beb3449109242325E941;
    address constant BEHYPE_USD_PYTH = 0x666a9807C632fFAA335C58C724bff38278392ec6;
    address constant EURC_USD_PYTH = 0x2B132ce03411Da6d3A73A93aA259d232FE525af9;

    // --- Veda accountants (OP), from the live PriceProviderV2 config ---
    address constant SETHFI_ACCOUNTANT = 0x05A1552c5e18F5A0BB9571b5F2D6a4765ebdA32b; // rate in ETHFI
    address constant LIQUID_ETH_ACCOUNTANT = 0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198; // rate in ETH
    address constant LIQUID_BTC_ACCOUNTANT = 0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0; // rate in BTC
    address constant LIQUID_USD_ACCOUNTANT = 0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7; // rate in USDC
    address constant EBTC_ACCOUNTANT = 0x1b293DC39F94157fA0D1D36d7e0090C8B8B8c13F; // rate in BTC
    address constant EUSD_ACCOUNTANT = 0xEB440B36f61Bf62E0C54C622944545f159C3B790; // rate in USDe

    // --- Midas 8-dec latestRoundData proxies (OP) ---
    address constant WEEUR_EUR_PROXY = 0x01b910C1aa51cdC4a2a84d76CB255C4974Bf8A19; // weEUR/EUR
    address constant LIQUID_RESERVE_USD_PROXY = 0x58dDf77A329CcbE2F4C2114C64ed9E12Ec8a1356;
    address constant LIQUID_RWA_USD_PROXY = 0xd5aaE6ac1a9ed4BE5DcC1fc172EDeFFd5B6d8080;

    uint8 constant FEED_DECIMALS = 8;
    // PriceProviderV2 staleness per token: 2 days for most sources, 1 day OP, 5 days frxUSD,
    // 7 days for the roughly-weekly Midas proxies
    uint256 constant DEFAULT_MAX_STALENESS = 2 days;
    uint256 constant OP_MAX_STALENESS = 1 days;
    uint256 constant FRXUSD_MAX_STALENESS = 5 days;
    uint256 constant MIDAS_MAX_STALENESS = 7 days;

    string json;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet");

        vm.startBroadcast();

        // Shared USD legs, also the direct reserve feeds for WETH, USDC, USDT, frxUSD, OP.
        // USDC/USDT/frxUSD keep PriceProviderV2's stable snap-to-$1.
        address ethUsd = _chainlink(ETH_USD_ORACLE, address(0), DEFAULT_MAX_STALENESS, false, "ETH / USD");
        address btcUsd = _chainlink(BTC_USD_ORACLE, address(0), DEFAULT_MAX_STALENESS, false, "BTC / USD");
        address usdcUsd = _chainlink(USDC_USD_ORACLE, address(0), DEFAULT_MAX_STALENESS, true, "USDC / USD");
        _chainlink(USDT_USD_ORACLE, address(0), DEFAULT_MAX_STALENESS, true, "USDT / USD");
        _chainlink(FRXUSD_USD_ORACLE, address(0), FRXUSD_MAX_STALENESS, true, "frxUSD / USD");
        _chainlink(OP_USD_ORACLE, address(0), OP_MAX_STALENESS, false, "OP / USD");
        _chainlink(WEETH_ETH_ORACLE, ethUsd, DEFAULT_MAX_STALENESS, false, "weETH / USD");

        // Pyth-priced assets (ETHFI/USD is reused as sETHFI's leg, EURC/USD as weEUR's)
        address ethfiUsd = _pyth(ETHFI_USD_PYTH, "ETHFI / USD");
        _pyth(WHYPE_USD_PYTH, "wHYPE / USD");
        _pyth(BEHYPE_USD_PYTH, "beHYPE / USD");
        address eurcUsd = _pyth(EURC_USD_PYTH, "EURC / USD");

        // Veda receipt tokens (accountant rate x underlying leg)
        _veda(SETHFI_ACCOUNTANT, ethfiUsd, "sETHFI / USD");
        _veda(LIQUID_ETH_ACCOUNTANT, ethUsd, "liquidETH / USD");
        _veda(LIQUID_BTC_ACCOUNTANT, btcUsd, "liquidBTC / USD");
        _veda(LIQUID_USD_ACCOUNTANT, usdcUsd, "liquidUSD / USD");
        _veda(EBTC_ACCOUNTANT, btcUsd, "eBTC / USD");
        // Mirrors PriceProviderV2, which takes the eUSD accountant rate as the USD price outright.
        // The vault is USDe-denominated, so this prices USDe at par with USD.
        _veda(EUSD_ACCOUNTANT, address(0), "eUSD / USD");

        // Midas proxies: USD-quoted except weEUR, which is EUR-quoted and composed on EURC/USD
        // the way PriceProviderV2 does
        _chainlink(WEEUR_EUR_PROXY, eurcUsd, MIDAS_MAX_STALENESS, false, "weEUR / USD");
        _chainlink(LIQUID_RESERVE_USD_PROXY, address(0), MIDAS_MAX_STALENESS, false, "liquidRESERVE / USD");
        _chainlink(LIQUID_RWA_USD_PROXY, address(0), MIDAS_MAX_STALENESS, false, "liquidRWA / USD");

        vm.stopBroadcast();

        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        vm.writeJson(vm.serializeString("summer-lend-prod-root", "details", json), path);
        console.log("Feed addresses written to:", path);
    }

    /// @dev Deploys a ChainlinkPriceFeed over a latestRoundData oracle, optionally composed on an underlying feed
    function _chainlink(address oracle, address underlyingUsdFeed, uint256 maxStaleness, bool stable, string memory desc) internal returns (address) {
        return _deployed(address(new ChainlinkPriceFeed(IAggregatorV3(oracle), IAaveV4PriceFeed(underlyingUsdFeed), FEED_DECIMALS, maxStaleness, stable, desc)), desc);
    }

    /// @dev Deploys a PythPriceFeed over a USD-quoted per-pair oracle
    function _pyth(address pairOracle, string memory desc) internal returns (address) {
        return _deployed(address(new PythPriceFeed(IPythPairOracle(pairOracle), PYTH_ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), DEFAULT_MAX_STALENESS, false, desc)), desc);
    }

    /// @dev Deploys a VedaAccountantPriceFeed, optionally composed on an underlying feed
    function _veda(address accountant, address underlyingUsdFeed, string memory desc) internal returns (address) {
        return _deployed(address(new VedaAccountantPriceFeed(IVedaAccountant(accountant), IAaveV4PriceFeed(underlyingUsdFeed), FEED_DECIMALS, DEFAULT_MAX_STALENESS, false, desc)), desc);
    }

    /// @dev Requires a live price, prints it for the eyeball check, and records the feed in the output JSON
    function _deployed(address feed, string memory desc) internal returns (address) {
        int256 answer = IAaveV4PriceFeed(feed).latestAnswer();
        require(answer > 0, string.concat("dead feed: ", desc));
        // 8-decimal USD, printed as dollars.cents
        uint256 usd = answer.toUint256();
        uint256 cents = (usd % 1e8) / 1e6;
        console.log(string.concat("  ", desc, ": $", vm.toString(usd / 1e8), cents < 10 ? ".0" : ".", vm.toString(cents), " at ", vm.toString(feed)));
        // Nested like the dev manifest: .details.<symbol>.oracle
        json = vm.serializeString("summer-lend-prod-feeds", _symbol(desc), vm.serializeAddress(string.concat("feed-", desc), "oracle", feed));
        return feed;
    }

    /// @dev The token symbol: the description prefix before " / USD"
    function _symbol(string memory desc) internal pure returns (string memory) {
        bytes memory b = bytes(desc);
        uint256 end;
        while (end < b.length && b[end] != " ") {
            end++;
        }
        bytes memory out = new bytes(end);
        for (uint256 i; i < end; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }
}
