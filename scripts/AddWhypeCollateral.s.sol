// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { PriceProvider } from "../src/oracle/PriceProvider.sol";
import { Utils } from "./utils/Utils.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";

contract AddWhypeCollateral is Utils {
    // beHYPE token on Scroll
    address beHype = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    
    // Reuse ETHFI oracle as requested
    address ethfiUsdOracle = 0xECA49340544541957eC64B7635418D2159616826;
    
    function run() public {
        vm.startBroadcast();
        
        string memory deployments = readDeploymentFile();

        address priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );

        address debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        // Configure beHYPE to use ETHFI oracle temporarily
        PriceProvider.Config memory beHypeUsdConfig = PriceProvider.Config({
            oracle: ethfiUsdOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(ethfiUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](1);
        tokens[0] = beHype;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = beHypeUsdConfig;

        // Set the price provider config for beHYPE
        PriceProvider(priceProvider).setTokenConfig(tokens, priceProviderConfigs);

        // beHYPE collateral config with specified risk parameters
        IDebtManager.CollateralTokenConfig memory beHypeConfig = IDebtManager.CollateralTokenConfig({
            ltv: 40e18,                   
            liquidationThreshold: 60e18,     
            liquidationBonus: 5e18          
        }); 

        // Add beHYPE as a supported collateral token
        IDebtManager(debtManager).supportCollateralToken(beHype, beHypeConfig);

        vm.stopBroadcast();
    }
}

