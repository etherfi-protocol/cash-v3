// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract DeployBeHYPEStakeModule is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address l2BeHypeStaker = 0x3f1Bdae959cEd680E434Fe201861E97976eA4A8F;
    address whypeToken = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address beHypeToken = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    uint32 refundGasLimit = 5_000;

    BeHYPEStakeModule public beHypeStakeModule;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        vm.startBroadcast(deployerPrivateKey);

        beHypeStakeModule = new BeHYPEStakeModule(
            dataProvider,
            l2BeHypeStaker,
            whypeToken,
            beHypeToken,
            refundGasLimit
        );


        vm.stopBroadcast();
    }
}

