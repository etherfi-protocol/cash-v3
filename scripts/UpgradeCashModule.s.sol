// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {CashModuleSetters} from "../src/modules/cash/CashModuleSetters.sol";
import {CashModuleCore} from "../src/modules/cash/CashModuleCore.sol";
import {ICashModule} from "../src/interfaces/ICashModule.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradeCashModule is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        UUPSUpgradeable cashModule = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashModule"))
        ));

        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        CashModuleCore cashModuleCoreImpl = new CashModuleCore(dataProvider);
        CashModuleSetters cashModuleSettersImpl = new CashModuleSetters(dataProvider);

        cashModule.upgradeToAndCall(address(cashModuleCoreImpl), "");
        ICashModule(address(cashModule)).setCashModuleSettersAddress(address(cashModuleSettersImpl));

        vm.stopBroadcast();
    }
}