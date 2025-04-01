// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradeDataProvider is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        UUPSUpgradeable dataProvider = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        ));

        EtherFiDataProvider etherFiDataProviderImpl = new EtherFiDataProvider();

        dataProvider.upgradeToAndCall(address(etherFiDataProviderImpl), "");

        address[] memory defaultModules = new address[](1);
        defaultModules[0] = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashModule"))
        );

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        EtherFiDataProvider(address(dataProvider)).configureDefaultModules(defaultModules, shouldWhitelist);

        vm.stopBroadcast();
    }
}