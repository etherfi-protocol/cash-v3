// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProvider } from "../../src/oracle/PriceProvider.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetHypeCollateralConfig is GnosisHelpers, Utils, Test {
    
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // HYPE tokens on Scroll
    address public beHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address public wHYPE = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;

    address debtManager;
    address priceProvider;
    
    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );

        // Price provider configs (oracle set to address(0) - UPDATE LATER!)
        PriceProvider.Config memory wHypeUsdConfig = PriceProvider.Config({
            oracle: address(0),  // TODO: Update with actual oracle address
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,  // Standard Chainlink decimals
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        PriceProvider.Config memory beHypeUsdConfig = PriceProvider.Config({
            oracle: address(0),  // TODO: Update with actual oracle address
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,  // Standard Chainlink decimals
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](2);
        tokens[0] = wHYPE;
        tokens[1] = beHYPE;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](2);
        priceProviderConfigs[0] = wHypeUsdConfig;
        priceProviderConfigs[1] = beHypeUsdConfig;

        // wHYPE config: LTV 45%, LT 65%, Liquidation Bonus 4%
        IDebtManager.CollateralTokenConfig memory wHypeConfig = IDebtManager.CollateralTokenConfig({
            ltv: 45e18,
            liquidationThreshold: 65e18,
            liquidationBonus: 4e18
        }); 

        // beHYPE config: LTV 40%, LT 60%, Liquidation Bonus 5%
        IDebtManager.CollateralTokenConfig memory beHypeConfig = IDebtManager.CollateralTokenConfig({
            ltv: 40e18,
            liquidationThreshold: 60e18,
            liquidationBonus: 5e18
        }); 

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // Set price provider configs for both tokens
        string memory setPriceConfigs = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, priceProviderConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), setPriceConfigs, "0", false)));

        // Support wHYPE as collateral token
        string memory supportWHype = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, wHYPE, wHypeConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), supportWHype, "0", false)));
        
        // Support beHYPE as collateral token (last transaction)
        string memory supportBeHype = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, beHYPE, beHypeConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), supportBeHype, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = "./output/SetHypeCollateralConfig.json";
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);
    }
}

