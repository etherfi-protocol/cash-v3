// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SettlementDispatcher} from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradeSettlementDispatcher is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        UUPSUpgradeable settlementDispatcher = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcher"))
        ));

        address settlementDispatcherImpl = address(new SettlementDispatcher());
        settlementDispatcher.upgradeToAndCall(address(settlementDispatcherImpl), "");

        vm.stopBroadcast();
    }

}