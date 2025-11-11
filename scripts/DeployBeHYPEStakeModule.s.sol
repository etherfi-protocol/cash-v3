// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BeHYPEStakeModule} from "../src/modules/hype/BeHYPEStakeModule.sol";
import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";
import {Utils} from "./utils/Utils.sol";

contract DeployBeHYPEStakeModule is Utils {
    address public constant L2_BEHYPE_STAKER = 0x3f1Bdae959cEd680E434Fe201861E97976eA4A8F;
    address public constant WHYPE_TOKEN = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address public constant BEHYPE_TOKEN = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;

    BeHYPEStakeModule public beHypeStakeModule;

    function run() public {

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        vm.startBroadcast();

        beHypeStakeModule = new BeHYPEStakeModule(dataProvider, L2_BEHYPE_STAKER, WHYPE_TOKEN, BEHYPE_TOKEN, 5_000);

        address[] memory modules = new address[](1);
        modules[0] = address(beHypeStakeModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, shouldWhitelist);

        vm.stopBroadcast();
    }
}
