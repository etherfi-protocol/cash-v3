// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {CashEventEmitter} from "../src/modules/cash/CashEventEmitter.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradeCashEventEmitter is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        UUPSUpgradeable cashEventEmitter = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashEventEmitter"))
        ));

        address cashModule = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashModule"))
        );

        CashEventEmitter cashEventEmitterImpl = new CashEventEmitter(cashModule);

        cashEventEmitter.upgradeToAndCall(address(cashEventEmitterImpl), "");

        vm.stopBroadcast();
    }
}