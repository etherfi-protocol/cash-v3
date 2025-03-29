// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { PriceProvider, IAggregatorV3 } from "../src/oracle/PriceProvider.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../src/interfaces/ILayerZeroTeller.sol";
import { Utils } from "./utils/Utils.sol";

contract PriceProviderSetTokenConfig is Utils {
    IERC20 public weth = IERC20(0x5300000000000000000000000000000000000004);
    IERC20 public weEth = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    IERC20 public usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 public usdt = IERC20(0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df);
    IERC20 public dai = IERC20(0xcA77eB3fEFe3725Dc33bccB54eDEFc3D9f764f97);
    IERC20 public wbtc = IERC20(0x3C1BCa5a656e69edCD0D4E36BEbb3FcDAcA60Cf1);
    IERC20 public usde = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);

    address public btcUsdOracle = 0x91429ddc50B38bAF3Ba9CB5eB0275507Ac65CBF4;
    
    IERC20 public liquidEth = IERC20(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    ILayerZeroTeller public liquidEthTeller = ILayerZeroTeller(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    ILayerZeroTeller public liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
    IERC20 public liquidBtc = IERC20(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    ILayerZeroTeller public liquidBtcTeller = ILayerZeroTeller(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353) ;

    IERC20 public eUsd = IERC20(0x939778D83b46B456224A33Fb59630B11DEC56663);
    ILayerZeroTeller public eUsdTeller = ILayerZeroTeller(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA) ;

    address public ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory deployments = readDeploymentFile();

        address priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );

        vm.startBroadcast(privateKey);
        
        PriceProvider.Config memory btcUsdConfig = PriceProvider.Config({
            oracle: btcUsdOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(btcUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        AccountantWithRateProviders liquidEthAccountant = liquidEthTeller.accountant();

        PriceProvider.Config memory liquidEthConfig = PriceProvider.Config({
            oracle: address(liquidEthAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidEthAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: true,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        AccountantWithRateProviders liquidBtcAccountant = liquidBtcTeller.accountant();

        PriceProvider.Config memory liquidBtcConfig = PriceProvider.Config({
            oracle: address(liquidBtcAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidBtcAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: true
        });

        AccountantWithRateProviders liquidUsdAccountant = liquidUsdTeller.accountant();

        PriceProvider.Config memory liquidUsdConfig = PriceProvider.Config({
            oracle: address(liquidUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        AccountantWithRateProviders eUsdAccountant = eUsdTeller.accountant();

        PriceProvider.Config memory eUsdConfig = PriceProvider.Config({
            oracle: address(eUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: eUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        address[] memory assets = new address[](5);
        assets[0] = address(wbtc);
        assets[1] = address(liquidEth);
        assets[2] = address(liquidBtc);
        assets[3] = address(liquidUsd);
        assets[4] = address(eUsd);

        PriceProvider.Config[] memory config = new PriceProvider.Config[](5);
        config[0] = btcUsdConfig;
        config[1] = liquidEthConfig;
        config[2] = liquidBtcConfig;
        config[3] = liquidUsdConfig;
        config[4] = eUsdConfig;

        PriceProvider(priceProvider).setTokenConfig(assets, config);

        vm.stopBroadcast();
    }
}