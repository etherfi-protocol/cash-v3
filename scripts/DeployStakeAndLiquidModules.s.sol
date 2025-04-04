// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiStakeModule } from "../src/modules/etherfi/EtherFiStakeModule.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";
import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";

contract DeployStakeAndLiquidModules is Utils {
    address public weth = address(0x5300000000000000000000000000000000000004);

    address public liquidEth = address(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    address public liquidEthTeller = address(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    
    address public liquidUsd = address(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    address public liquidUsdTeller = address(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
    address public liquidBtc = address(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    address public liquidBtcTeller = address(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);

    address public eUsd = address(0x939778D83b46B456224A33Fb59630B11DEC56663);
    address public eUsdTeller = address(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA);

    address weEth = address(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    address syncPool = 0x750cf0fd3bc891D8D864B732BC4AD340096e5e68;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );  

        address[] memory assets = new address[](4);
        assets[0] = liquidEth;
        assets[1] = liquidBtc;
        assets[2] = liquidUsd;
        assets[3] = eUsd;

        address[] memory tellers = new address[](4);
        tellers[0] = liquidEthTeller;
        tellers[1] = liquidBtcTeller;
        tellers[2] = liquidUsdTeller;
        tellers[3] = eUsdTeller;

        EtherFiLiquidModule liquidModule = new EtherFiLiquidModule(assets, tellers, dataProvider, weth);
        EtherFiStakeModule stakeModule = new EtherFiStakeModule(dataProvider, syncPool, weth, weEth);

        address[] memory defaultModules = new address[](2);
        defaultModules[0] = address(liquidModule);
        defaultModules[1] = address(stakeModule);

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        EtherFiDataProvider(dataProvider).configureDefaultModules(defaultModules, shouldWhitelist);
        vm.stopBroadcast();
    }
}