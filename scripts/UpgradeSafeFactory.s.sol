// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {EtherFiSafe} from "../src/safe/EtherFiSafe.sol";
import {EtherFiSafeFactory} from "../src/safe/EtherFiSafeFactory.sol";
import {Utils} from "./utils/Utils.sol";

contract UpgradeSafeFactory is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);  

        string memory deployments = readDeploymentFile();

        UUPSUpgradeable safeFactory = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string.concat(".", "addresses", ".", "EtherFiSafeFactory")
        ));

        address newImpl = address(new EtherFiSafeFactory());

        safeFactory.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();
    }
}