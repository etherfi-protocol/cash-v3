// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {PriceProviderV2} from "../../src/oracle/PriceProviderV2.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";
import {Utils} from "../utils/Utils.sol";

// forge script scripts/gnosis-txs/UpgradeToPriceProviderV2.s.sol:UpgradeToPriceProviderV2Gnosis --rpc-url optimism --broadcast --verify -vvvv
contract UpgradeToPriceProviderV2Gnosis is GnosisHelpers, Utils {
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // ---------------------------------------------------------------
    // OP token addresses
    // ---------------------------------------------------------------
    address constant ETH_SELECTOR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant BTC_SELECTOR = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;

    address constant USDC   = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant USDT   = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant FRAX_USD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;

    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WEETH  = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant WHYPE  = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address constant BEHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address constant ETHFI  = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant EURC   = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;

    address constant LIQUID_ETH     = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant LIQUID_BTC     = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant LIQUID_USD     = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant LIQUID_RESERVE = 0xE5d3854736e0D513aAE2D8D708Ad94d14Fd56A6a;
    address constant EUSD           = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant EBTC           = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant LIQUID_EUR    = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;

    // ---------------------------------------------------------------
    // OP oracle addresses
    // ---------------------------------------------------------------

    // Chainlink type
    address constant ETH_USD_ORACLE       = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address constant BTC_USD_ORACLE       = 0xD702DD976Fb76Fffc2D3963D037dfDae5b04E593;
    address constant USDC_USD_ORACLE      = 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3;
    address constant USDT_USD_ORACLE      = 0xECef79E109e997bCA29c1c0897ec9d7b03647F5E;
    address constant FRAX_USD_ORACLE      = 0x8BF42811876e1B692d0E70F61b80e1fbc68Ef1bf;
    address constant WEETH_ETH_ORACLE     = 0xb4479d436DDa5c1A79bD88D282725615202406E3;
    address constant LIQUID_RESERVE_ORACLE = 0x58dDf77A329CcbE2F4C2114C64ed9E12Ec8a1356;
    address constant LIQUID_EUR_ORACLE   = 0x01b910C1aa51cdC4a2a84d76CB255C4974Bf8A19; 
    
    // Pyth type
    address constant WHYPE_USD_ORACLE     = 0x1f860581483253B81ECB0E89b2b978A202de553d;
    address constant BEHYPE_USD_ORACLE    = 0x2ACd77fefED51Fa80FBF1520701c73Ac506D4381;
    address constant ETHFI_USD_ORACLE     = 0x3E377b4e02bc848Ade3c289477F21441b7e014C2;
    address constant SETHFI_ORACLE        = 0x8454985aA5bc30162aC258D3CCf89E9BA6604d99;
    address constant EUR_USD_ORACLE       = 0x62779cdAadd1eB782eb4fF534739B55763A48385;
    
    // Accountant type
    address constant LIQUID_ETH_ORACLE    = 0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198;
    address constant LIQUID_BTC_ORACLE    = 0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0;
    address constant LIQUID_USD_ORACLE    = 0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7;    
    address constant EUSD_ORACLE          = 0xEB440B36f61Bf62E0C54C622944545f159C3B790;
    address constant EBTC_ORACLE          = 0x1b293DC39F94157fA0D1D36d7e0090C8B8B8c13F;

    // ---------------------------------------------------------------
    // Custom oracle calldata selectors
    // ---------------------------------------------------------------
    bytes constant GET_RATE_CALLDATA = hex"679aefce"; // AccountantWithRateProviders.getRate()
    bytes constant PYTH_CALLDATA   = hex"a035b1fe"; // price()

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");

        vm.startBroadcast();

        // Deploy new implementation
        address priceProviderV2Impl = address(new PriceProviderV2());

        (address[] memory tokens, PriceProviderV2.Config[] memory configs) = _buildConfigs();

        // Build gnosis tx bundle: upgrade + setTokenConfig
        string memory txs = _getGnosisHeader(chainId, addressToHex(CASH_CONTROLLER_SAFE));

        // Tx 1: Upgrade proxy to V2 impl and set all configs atomically
        string memory upgradeAndSetConfig = iToHex(abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector,
            priceProviderV2Impl,
            abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs)
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), upgradeAndSetConfig, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeToPriceProviderV2.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        // Simulate: execute gnosis tx bundle and verify prices
        executeGnosisTransactionBundle(path);

        PriceProviderV2 priceProviderV2 = PriceProviderV2(priceProvider);
        uint8 priceDecimals = priceProviderV2.decimals();

        console.log("");
        console.log("=== PriceProviderV2 prices (decimals: %d) ===", priceDecimals);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 p = priceProviderV2.price(tokens[i]);
            console.log("%s (%s): %d", _tokenLabel(tokens[i]), vm.toString(tokens[i]), p);
            require(p > 0, string.concat("Price is 0 for ", _tokenLabel(tokens[i])));
        }
    }

    function _tokenLabel(address token) internal pure returns (string memory) {
        if (token == ETH_SELECTOR) return "ETH";
        if (token == BTC_SELECTOR) return "BTC";
        if (token == USDC) return "USDC";
        if (token == USDT) return "USDT";
        if (token == FRAX_USD) return "fraxUSD";
        if (token == WETH) return "WETH";
        if (token == WEETH) return "weETH";
        if (token == WHYPE) return "wHYPE";
        if (token == BEHYPE) return "beHYPE";
        if (token == ETHFI) return "ETHFI";
        if (token == SETHFI) return "sETHFI";
        if (token == EURC) return "EURC";
        if (token == LIQUID_ETH) return "liquidETH";
        if (token == LIQUID_BTC) return "liquidBTC";
        if (token == LIQUID_USD) return "liquidUSD";
        if (token == LIQUID_RESERVE) return "liquidReserve";
        if (token == EUSD) return "eUSD";
        if (token == EBTC) return "eBTC";
        if (token == LIQUID_EUR) return "liquidEUR";
        return "UNKNOWN";
    }

    function _buildConfigs() internal pure returns (address[] memory tokens, PriceProviderV2.Config[] memory configs) {
        tokens = new address[](19);
        configs = new PriceProviderV2.Config[](19);

        uint256 i = 0;

        // ---- Base assets first (baseAsset = address(0)) ----

        // ETH/USD
        tokens[i] = ETH_SELECTOR;
        configs[i] = PriceProviderV2.Config({
            oracle: ETH_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        // BTC/USD
        tokens[i] = BTC_SELECTOR;
        configs[i] = PriceProviderV2.Config({
            oracle: BTC_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        // EUR/USD (EURC address used as the EUR base asset key)
        tokens[i] = EURC;
        configs[i] = PriceProviderV2.Config({
            oracle: EUR_USD_ORACLE,
            priceFunctionCalldata: PYTH_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 16,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        // WETH (same oracle as ETH)
        tokens[i] = WETH;
        configs[i] = PriceProviderV2.Config({
            oracle: ETH_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        // ---- Stablecoins ----

        tokens[i] = USDC;
        configs[i] = PriceProviderV2.Config({
            oracle: USDC_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = USDT;
        configs[i] = PriceProviderV2.Config({
            oracle: USDT_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = FRAX_USD;
        configs[i] = PriceProviderV2.Config({
            oracle: FRAX_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 18,
            maxStaleness: 5 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        i++;

        // ---- Direct USD Chainlink ----

        tokens[i] = WHYPE;
        configs[i] = PriceProviderV2.Config({
            oracle: WHYPE_USD_ORACLE,
            priceFunctionCalldata: PYTH_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 16,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = BEHYPE;
        configs[i] = PriceProviderV2.Config({
            oracle: BEHYPE_USD_ORACLE,
            priceFunctionCalldata: PYTH_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 16,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = ETHFI;
        configs[i] = PriceProviderV2.Config({
            oracle: ETHFI_USD_ORACLE,
            priceFunctionCalldata: PYTH_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 16,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = LIQUID_RESERVE;
        configs[i] = PriceProviderV2.Config({
            oracle: LIQUID_RESERVE_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 7 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        // ---- Custom oracle, direct USD ----

        tokens[i] = SETHFI;
        configs[i] = PriceProviderV2.Config({
            oracle: SETHFI_ORACLE,
            priceFunctionCalldata: PYTH_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 16,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = LIQUID_USD;
        configs[i] = PriceProviderV2.Config({
            oracle: LIQUID_USD_ORACLE,
            priceFunctionCalldata: GET_RATE_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 6,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: USDC
        });
        i++;

        tokens[i] = EUSD;
        configs[i] = PriceProviderV2.Config({
            oracle: EUSD_ORACLE,
            priceFunctionCalldata: GET_RATE_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 18,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        // ---- ETH-denominated (baseAsset = ETH) ----

        tokens[i] = WEETH;
        configs[i] = PriceProviderV2.Config({
            oracle: WEETH_ETH_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 18,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: ETH_SELECTOR
        });
        i++;

        tokens[i] = LIQUID_ETH;
        configs[i] = PriceProviderV2.Config({
            oracle: LIQUID_ETH_ORACLE,
            priceFunctionCalldata: GET_RATE_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 18,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: ETH_SELECTOR
        });
        i++;

        // ---- BTC-denominated (baseAsset = BTC) ----

        tokens[i] = LIQUID_BTC;
        configs[i] = PriceProviderV2.Config({
            oracle: LIQUID_BTC_ORACLE,
            priceFunctionCalldata: GET_RATE_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: BTC_SELECTOR
        });
        i++;

        tokens[i] = EBTC;
        configs[i] = PriceProviderV2.Config({
            oracle: EBTC_ORACLE,
            priceFunctionCalldata: GET_RATE_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: BTC_SELECTOR
        });
        i++;

        // ---- EUR-denominated (baseAsset = EURC) ----

        // liquidEURC
        tokens[i] = LIQUID_EUR;
        configs[i] = PriceProviderV2.Config({
            oracle: LIQUID_EUR_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 7 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: EURC
        });
        i++;

        require(i == 19, "Token count mismatch");
    }
}
