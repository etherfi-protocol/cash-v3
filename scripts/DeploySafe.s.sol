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

        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        address swapModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "OpenOceanSwapModule")
        );

        address[] memory owners = new address[](1);
        owners[0] = deployer;

        address[] memory modules = new address[](2);
        modules[0] = cashModule;
        modules[1] = swapModule;
        bytes[] memory moduleSetupData = new bytes[](2);
        moduleSetupData[0] = abi.encode(10000e6, 10000e6, -5 * 3600);
        uint8 threshold = 1;

        address[] memory modules = new address[](2);
        modules[0] = cashModule;
        modules[1] = swapModule;
        bytes[] memory moduleSetupData = new bytes[](2);
        moduleSetupData[0] = abi.encode(dailySpendLimit, monthlySpendLimit, timezoneOffset);
        
        
        bytes32 salt = keccak256("user1");
        factory.deployEtherFiSafe(salt, owners, modules, moduleSetupData, threshold);

        vm.stopBroadcast();
    }
}