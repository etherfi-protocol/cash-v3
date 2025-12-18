// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiLiquidModuleWithReferrer } from "../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { Utils } from "./utils/Utils.sol";  

contract DeployEtherFiLiquidModuleWithReferrer is Utils {
    address public weth = address(0x5300000000000000000000000000000000000004);    
    address public ethfi = address(0x056A5FA5da84ceb7f93d36e545C5905607D8bD81);
    address public sethfi = address(0x86B5780b606940Eb59A062aA85a07959518c0161);
    address public sethfiTeller = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;
    address public sETHFIBoringQueue = address(0xF03352da1536F31172A7F7cB092D4717DeDDd3CB);

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        ); 
        address cashModule = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashModule"))
        );

        vm.startBroadcast(deployerPrivateKey);

        address[] memory assets = new address[](1);
        assets[0] = address(sethfi);
        
        address[] memory tellers = new address[](1);
        tellers[0] = sethfiTeller;

        bool[] memory isWithdrawAsset = new bool[](1);
        isWithdrawAsset[0] = true;

        EtherFiLiquidModuleWithReferrer liquidModule = new EtherFiLiquidModuleWithReferrer(assets, tellers, address(dataProvider), address(weth));
        
        ICashModule(cashModule).configureWithdrawAssets(assets, isWithdrawAsset);
        ICashModule(cashModule).configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, shouldWhitelist);
        
        liquidModule.setLiquidAssetWithdrawQueue(address(sethfi), address(sETHFIBoringQueue));

        vm.stopBroadcast();
    }
}