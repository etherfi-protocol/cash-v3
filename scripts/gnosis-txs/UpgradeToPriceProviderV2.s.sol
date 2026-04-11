// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {PriceProviderV2} from "../../src/oracle/PriceProviderV2.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";
import {Utils} from "../utils/Utils.sol";

contract UpgradeToPriceProviderV2Gnosis is GnosisHelpers, Utils {
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // ---------------------------------------------------------------
    // Scroll token addresses
    // ---------------------------------------------------------------
    address constant ETH_SELECTOR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant BTC_SELECTOR = 0x3C1BCa5a656e69edCD0D4E36BEbb3FcDAcA60Cf1;

    address constant USDC   = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant USDT   = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address constant FRAX_USD = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;

    address constant WETH   = 0x5300000000000000000000000000000000000004;
    address constant WEETH  = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address constant SCR    = 0xd29687c813D741E2F938F4aC377128810E217b1b;
    address constant WHYPE  = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address constant BEHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address constant ETHFI  = 0x056A5FA5da84ceb7f93d36e545C5905607D8bD81;
    address constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant EURC   = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;

    address constant LIQUID_ETH     = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant LIQUID_BTC     = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant LIQUID_USD     = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant LIQUID_RESERVE = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address constant EUSD           = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant EBTC           = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant LIQUID_EURC    = 0xBC43Df01195F5b67243179360189BcA2f86Aa584;

    // ---------------------------------------------------------------
    // Scroll oracle addresses
    // ---------------------------------------------------------------
    address constant ETH_USD_ORACLE       = 0x66A8cb6c4230B044378aC3676D47Ed4fE18e3cFB;
    address constant BTC_USD_ORACLE       = 0x91429ddc50B38bAF3Ba9CB5eB0275507Ac65CBF4;
    address constant USDC_USD_ORACLE      = 0x9Cf01269e491375DBe3C725927Aa025BAc47bEeB;
    address constant USDT_USD_ORACLE      = 0xf376A91Ae078927eb3686D6010a6f1482424954E;
    address constant FRAX_USD_ORACLE      = 0x7be4f8b373853b74CDf48FE817bC2eB2272eBe45;
    address constant WEETH_ETH_ORACLE     = 0x800Ca870416CDFEf77991036B8e1f2E51623996E;
    address constant SCR_USD_ORACLE       = 0x145234c9C1f1583E710bdC2926d6E97e4523ef93;
    address constant WHYPE_USD_ORACLE     = 0x1ef9592F449761C6EdA75c1fCFC45D625F3d5C76;
    address constant BEHYPE_USD_ORACLE    = 0xB7d02965989FC2E5Af605Ca4EAEe92328589772F;
    address constant ETHFI_USD_ORACLE     = 0xECA49340544541957eC64B7635418D2159616826;
    address constant SETHFI_ORACLE        = 0xeA99E12b06C1606FCae968Cc6ceBB1A7A323E0f5;
    address constant EUR_USD_ORACLE       = 0x8d60a2B5E87ac714F2Bba57140981B79440E5feF;
    address constant LIQUID_ETH_ORACLE    = 0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198;
    address constant LIQUID_BTC_ORACLE    = 0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0;
    address constant LIQUID_USD_ORACLE    = 0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7;
    address constant LIQUID_RESERVE_ORACLE = 0xB2a4eC4C9b95D7a87bA3989d0FD38dFfDd944A24;
    address constant EUSD_ORACLE          = 0xEB440B36f61Bf62E0C54C622944545f159C3B790;
    address constant EBTC_ORACLE          = 0x1b293DC39F94157fA0D1D36d7e0090C8B8B8c13F;
    address constant LIQUID_EURC_ORACLE   = 0x41D14b9E948e70549EDa102e0BC49Be0C245BfEf;

    // ---------------------------------------------------------------
    // Custom oracle calldata selectors
    // ---------------------------------------------------------------
    bytes constant GET_RATE_CALLDATA = hex"679aefce"; // AccountantWithRateProviders.getRate()
    bytes constant SETHFI_CALLDATA  = hex"50d25bcd"; // latestAnswer()

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
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 p = priceProviderV2.price(tokens[i]);
            require(p > 0, string.concat("Price is 0 for token index ", vm.toString(i)));
        }
    }

    function _buildConfigs() internal pure returns (address[] memory tokens, PriceProviderV2.Config[] memory configs) {
        tokens = new address[](20);
        configs = new PriceProviderV2.Config[](20);

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
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
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
            maxStaleness: 15 days,
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
            maxStaleness: 10 days,
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
            oraclePriceDecimals: 8,
            maxStaleness: 5 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        i++;

        // ---- Direct USD Chainlink ----

        tokens[i] = SCR;
        configs[i] = PriceProviderV2.Config({
            oracle: SCR_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = WHYPE;
        configs[i] = PriceProviderV2.Config({
            oracle: WHYPE_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = BEHYPE;
        configs[i] = PriceProviderV2.Config({
            oracle: BEHYPE_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        tokens[i] = ETHFI;
        configs[i] = PriceProviderV2.Config({
            oracle: ETHFI_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 3 days,
            dataType: PriceProviderV2.ReturnType.Int256,
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
            maxStaleness: 6 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        i++;

        // ---- Custom oracle, direct USD ----

        tokens[i] = SETHFI;
        configs[i] = PriceProviderV2.Config({
            oracle: SETHFI_ORACLE,
            priceFunctionCalldata: SETHFI_CALLDATA,
            isChainlinkType: false,
            oraclePriceDecimals: 8,
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
            baseAsset: address(0)
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
            oraclePriceDecimals: 8,
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
        tokens[i] = LIQUID_EURC;
        configs[i] = PriceProviderV2.Config({
            oracle: LIQUID_EURC_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 7 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: EURC
        });
        i++;

        require(i == 20, "Token count mismatch");
    }
}
