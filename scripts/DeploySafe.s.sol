// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";
import {EtherFiSafeFactory} from "../src/safe/EtherFiSafeFactory.sol";

contract DeploySafe is Utils {
    EtherFiSafeFactory factory;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        factory = EtherFiSafeFactory(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiSafeFactory")
        ));

        address[] memory owners = new address[](1);
        owners[0] = deployer;

        address[] memory modules = new address[](0);
        bytes[] memory moduleSetupData = new bytes[](0);
        uint8 threshold = 1;

        
        bytes32 salt = keccak256("user1");
        factory.deployEtherFiSafe(salt, owners, modules, moduleSetupData, threshold);

        vm.stopBroadcast();
    }
}