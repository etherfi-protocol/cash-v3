// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { Utils } from "./utils/Utils.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore, BinSponsor } from "../src/modules/cash/CashModuleCore.sol";
import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";

contract CashbackTypesUpgrade is Utils {
    address usdcToken = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    address eventEmitter;
    address cashModule;
    address dataProvider;
    address cashbackDispatcher;

    function run() public {
        string memory deployments = readDeploymentFile();

        eventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        cashbackDispatcher = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashbackDispatcher")
        );

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        address cashEventEmitterImpl = address(new CashEventEmitter(cashModule));

        UUPSUpgradeable(cashModule).upgradeToAndCall(cashModuleCoreImpl, "");
        UUPSUpgradeable(eventEmitter).upgradeToAndCall(cashEventEmitterImpl, "");

        address[] memory tokens = new address[](1);
        tokens[0] = usdcToken;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        CashbackDispatcher(cashbackDispatcher).configureCashbackToken(tokens, shouldWhitelist);

        vm.stopBroadcast();
    }
}