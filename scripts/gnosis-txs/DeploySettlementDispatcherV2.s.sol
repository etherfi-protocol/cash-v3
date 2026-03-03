// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { BinSponsor } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract DeploySettlementDispatcherV2 is Utils, Test, GnosisHelpers {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    SettlementDispatcherV2 settlementDispatcherV2Impl;
    UUPSProxy settlementDispatcherV2Proxy;

    address cashModule;
    address cashEventEmitter;
    address dataProvider;
    address roleRegistry;

    address cashModuleCoreImpl;
    address cashModuleSettersImpl;
    address cashEventEmitterImpl;

    function run() public {
        string memory deployments = readDeploymentFile();
        vm.startBroadcast();

        roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        cashEventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );

        require(roleRegistry != address(0), "Invalid roleRegistry");
        require(cashModule != address(0), "Invalid cashModule");
        require(cashEventEmitter != address(0), "Invalid cashEventEmitter");
        require(dataProvider != address(0), "Invalid dataProvider");

        // Deploy implementations
        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));

        settlementDispatcherV2Impl = new SettlementDispatcherV2(
            BinSponsor.CardOrder,
            dataProvider
        );

        address[] memory tokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](0);

        // Deploy proxy with initialization
        settlementDispatcherV2Proxy = new UUPSProxy(
            address(settlementDispatcherV2Impl),
            abi.encodeWithSelector(
                SettlementDispatcherV2.initialize.selector,
                roleRegistry,
                tokens,
                destDatas
            )
        );

        console.log("SettlementDispatcherV2 Implementation:", address(settlementDispatcherV2Impl));
        console.log("SettlementDispatcherV2 Proxy:", address(settlementDispatcherV2Proxy));

        string memory txs = getGnosisTransactions();

        vm.createDir("./output", true);
        string memory path = "./output/DeploySettlementDispatcherV2.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }

    function getGnosisTransactions() internal view returns (string memory) {
        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // Upgrade CashModuleCore
        string memory cashModuleCoreUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleCoreUpgrade, "0", false)));

        // Set CashModuleSetters address
        string memory cashModuleSettersUpgrade = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleSettersUpgrade, "0", false)));

        // Upgrade CashEventEmitter
        string memory cashEventEmitterUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashEventEmitter), cashEventEmitterUpgrade, "0", false)));

        // Set the settlement dispatcher for CardOrder
        string memory setSettlementDispatcher = iToHex(abi.encodeWithSelector(CashModuleSetters.setSettlementDispatcher.selector, BinSponsor.CardOrder, address(settlementDispatcherV2Proxy)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setSettlementDispatcher, "0", true)));

        return txs;
    }
}

