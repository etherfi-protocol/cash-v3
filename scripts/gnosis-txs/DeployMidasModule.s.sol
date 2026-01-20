// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { Utils } from "../utils/Utils.sol";

contract DeployMidasModule is Utils {
    address midasToken = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address depositVault = 0xcA1C871f8ae2571Cb126A46861fc06cB9E645152;
    address redemptionVault = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    function run() public {
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider")));

        vm.startBroadcast();

        // Prepare arrays for Midas module deployment
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = midasToken;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = depositVault;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = redemptionVault;

        // Deploy Midas module
        MidasModule midasModule = new MidasModule(dataProvider, midasTokens, depositVaults, redemptionVaults);

        vm.stopBroadcast();
    }
}
