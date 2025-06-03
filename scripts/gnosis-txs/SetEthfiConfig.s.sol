// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetEthfiConfig is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address ethfi = 0x056A5FA5da84ceb7f93d36e545C5905607D8bD81;
    address ethfiUsdOracle = 0xECA49340544541957eC64B7635418D2159616826;
    
    address debtManager;
    address priceProvider;
    
    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );

        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        PriceProvider.Config memory ethfiUsdConfig = PriceProvider.Config({
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
        tokens[0] = ethfi;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = ethfiUsdConfig;

        IDebtManager.CollateralTokenConfig memory ethfiConfig = IDebtManager.CollateralTokenConfig({
            ltv: 20e18,
            liquidationThreshold: 50e18,
            liquidationBonus: 5e18
        }); 

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory setEthfiPriceProviderConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, priceProviderConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), setEthfiPriceProviderConfig, "0", false)));
        
        string memory setEthfiConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, ethfi, ethfiConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setEthfiConfig, "0", true)));
        
        
        vm.createDir("./output", true);
        string memory path = "./output/SetEthfiConfig.json";
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        assert(IDebtManager(debtManager).isCollateralToken(ethfi) == true);
    }
}