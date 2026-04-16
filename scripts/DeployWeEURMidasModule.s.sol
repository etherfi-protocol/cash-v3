// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { MidasModule } from "../src/modules/midas/MidasModule.sol";
import { Utils } from "./utils/Utils.sol";

contract DeployWeEURMidasModule is Utils {
    bytes32 public constant SALT_MIDAS_MODULE = keccak256("DeployOptimismProdModules.MidasModule");

    address constant WEEUR_TOKEN = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address constant DEPOSIT_VAULT = 0xF1b45eE795C8e1B858e191654C95A1B33c573632;
    address constant REDEMPTION_VAULT = 0xDC87653FCc5c16407Cd2e199d5Db48BaB71e7861;

    function run() public {
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider")));

        vm.startBroadcast();

        address[] memory midasTokens = new address[](1);
        midasTokens[0] = WEEUR_TOKEN;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = DEPOSIT_VAULT;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = REDEMPTION_VAULT;

        address midasModule = deployWithCreate3(
            abi.encodePacked(type(MidasModule).creationCode, abi.encode(dataProvider, midasTokens, depositVaults, redemptionVaults)),
            SALT_MIDAS_MODULE
        );
        console.log("MidasModule:", midasModule);

        vm.stopBroadcast();
    }
}
