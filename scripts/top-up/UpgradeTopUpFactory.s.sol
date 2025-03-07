// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";

contract UpgradeTopUpFactory is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);  

        string memory deployments = readDeploymentFile();

        TopUpFactory factoryImpl = new TopUpFactory();

        UUPSUpgradeable topUpFactory = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        ));

        topUpFactory.upgradeToAndCall(address(factoryImpl), "");

        vm.stopBroadcast();
    }
}