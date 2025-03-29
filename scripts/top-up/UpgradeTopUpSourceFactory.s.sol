// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {TopUp} from "../../src/top-up/TopUp.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";

contract UpgradeTopUpSourceFactory is Utils {
    UUPSUpgradeable factory;

    function run() public {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast();
        string memory deployments = readTopUpSourceDeployment();

        factory = UUPSUpgradeable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        ));

        address factoryImpl = address(new TopUpFactory());

        factory.upgradeToAndCall(address(factoryImpl), "");

        vm.stopBroadcast();
    }
}
