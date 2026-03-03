// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { LiquidUSDLiquifierModule } from "../src/modules/etherfi/LiquidUSDLiquifier.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { Utils, ChainConfig } from "./utils/Utils.sol";

contract DeployLiquidUSDLiquifierModule is Utils {
    LiquidUSDLiquifierModule liquidUSDLiquifierModule;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast();

        string memory deployments = readDeploymentFile();

        address debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        bytes memory initializeData = abi.encodeWithSelector(LiquidUSDLiquifierModule.initialize.selector, roleRegistry);

        address liquidUSDLiquifierModuleImpl = address(new LiquidUSDLiquifierModule(debtManager, dataProvider));
        address liquidUSDLiquifierModuleProxy = address(new UUPSProxy(liquidUSDLiquifierModuleImpl, initializeData));
    
        // address[] memory modules = new address[](1);
        // modules[0] = liquidUSDLiquifierModuleProxy;

        // bool[] memory shouldWhitelist = new bool[](1);
        // shouldWhitelist[0] = true;

        // EtherFiDataProvider(dataProvider).configureDefaultModules(modules, shouldWhitelist);        

        vm.stopBroadcast();
    }
}
