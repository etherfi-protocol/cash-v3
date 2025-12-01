// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { BinSponsor, SettlementDispatcher } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { CashModuleCore } from "../src/modules/cash/CashModuleCore.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { Utils } from "./utils/Utils.sol";

contract DeploySettlementDispatcherV2Dev is Utils, Test {
    function run() public {
        string memory deployments = readDeploymentFile();
        vm.startBroadcast();

        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address cashEventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        
        CashModuleCore cashModuleCoreImpl = new CashModuleCore(dataProvider);
        CashModuleSetters cashModuleSettersImpl = new CashModuleSetters(dataProvider);
        CashEventEmitter cashEventEmitterImpl = new CashEventEmitter(cashModule);

        UUPSUpgradeable(cashModule).upgradeToAndCall(address(cashModuleCoreImpl), "");
        ICashModule(cashModule).setCashModuleSettersAddress(address(cashModuleSettersImpl));
        UUPSUpgradeable(cashEventEmitter).upgradeToAndCall(address(cashEventEmitterImpl), "");

        SettlementDispatcherV2 settlementDispatcherV2Impl = new SettlementDispatcherV2(
            BinSponsor.CardOrder,
            dataProvider
        );

        address[] memory tokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](0);

        // Deploy proxy with initialization
        UUPSProxy settlementDispatcherV2Proxy = new UUPSProxy(
            address(settlementDispatcherV2Impl),
            abi.encodeWithSelector(
                SettlementDispatcherV2.initialize.selector,
                roleRegistry,
                tokens,
                destDatas
            )
        );

        // Set the settlement dispatcher for CardOrder
        CashModuleSetters(cashModule).setSettlementDispatcher(
            BinSponsor.CardOrder,
            address(settlementDispatcherV2Proxy)
        );

        console.log("SettlementDispatcherV2 Implementation:", address(settlementDispatcherV2Impl));
        console.log("SettlementDispatcherV2 Proxy:", address(settlementDispatcherV2Proxy));

        vm.stopBroadcast();
    }
}

