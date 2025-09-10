// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore, BinSponsor } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract CashbackTypesUpgrade is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address usdcToken = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    
    address eventEmitter;
    address cashModule;
    address dataProvider;
    address cashbackDispatcher;
    
    address cashModuleCoreImpl;
    address cashEventEmitterImpl;
    
    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        cashbackDispatcher = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashbackDispatcher")
        );
        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        eventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        vm.startBroadcast();

        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcToken);

        bool[] memory isCashbackToken = new bool[](1);
        isCashbackToken[0] = true;

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        
        string memory upgradeCashModule = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCashModule, "0", false)));
        
        string memory upgradeCashEventEmitter = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(eventEmitter), upgradeCashEventEmitter, "0", false)));

        string memory setCashbackTokens = iToHex(abi.encodeWithSelector(CashbackDispatcher.configureCashbackToken.selector, tokens, isCashbackToken));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashbackDispatcher), setCashbackTokens, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/CashbackTypesUpgrade.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }
}