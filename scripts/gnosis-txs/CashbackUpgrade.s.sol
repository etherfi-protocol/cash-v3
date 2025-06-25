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

contract CashbackUpgrade is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address scrToken = 0xd29687c813D741E2F938F4aC377128810E217b1b;
    
    address eventEmitter;
    address cashModule;
    address cashLens;
    address debtManager;
    address dataProvider;
    address cashbackDispatcher;
    address payable settlementDispatcherReap;
    address payable settlementDispatcherRain;

    address cashbackDispatcherImpl;
    address cashModuleCoreImpl;
    address cashModuleSettersImpl;
    address cashEventEmitterImpl;
    address cashLensImpl;
    address settlementDispatcherReapImpl;
    address settlementDispatcherRainImpl;
    address debtManagerCoreImpl;
    address debtManagerAdminImpl;

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
        cashLens = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashLens")
        );
        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        eventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        settlementDispatcherReap = payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        ));
        settlementDispatcherRain = payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherRain")
        ));

        deploy();

        address[] memory tokens = new address[](1);
        tokens[0] = address(scrToken);

        bool[] memory isCashbackToken = new bool[](1);
        isCashbackToken[0] = true;

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        
        string memory upgradeCashbackDispatcher = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashbackDispatcherImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashbackDispatcher), upgradeCashbackDispatcher, "0", false)));
        
        string memory upgradeSettlementDispatcherReap = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherReapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), upgradeSettlementDispatcherReap, "0", false)));
        
        string memory upgradeSettlementDispatcherRain = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherRainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherRain), upgradeSettlementDispatcherRain, "0", false)));
        
        string memory upgradeDebtManager = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, debtManagerCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), upgradeDebtManager, "0", false)));
        
        string memory upgradeDebtManagerAdmin = iToHex(abi.encodeWithSelector(DebtManagerCore.setAdminImpl.selector, debtManagerAdminImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), upgradeDebtManagerAdmin, "0", false)));
        
        string memory upgradeCashModule = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCashModule, "0", false)));
        
        string memory upgradeCashModuleSetters = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCashModuleSetters, "0", false)));

        string memory upgradeCashEventEmitter = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(eventEmitter), upgradeCashEventEmitter, "0", false)));

        string memory upgradeCashLens = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashLensImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashLens), upgradeCashLens, "0", false)));

        string memory setCashbackTokens = iToHex(abi.encodeWithSelector(CashbackDispatcher.configureCashbackToken.selector, tokens, isCashbackToken));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashbackDispatcher), setCashbackTokens, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/CashbackUpgrade.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }

    function deploy() internal {
        vm.startBroadcast();

        cashbackDispatcherImpl = address(new CashbackDispatcher(dataProvider));
        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        cashLensImpl = address(new CashLens(cashModule, dataProvider));
        settlementDispatcherReapImpl = payable(address(new SettlementDispatcher(BinSponsor.Reap, dataProvider)));
        settlementDispatcherRainImpl = payable(address(new SettlementDispatcher(BinSponsor.Rain, dataProvider)));
        debtManagerCoreImpl = address(new DebtManagerCore(dataProvider));
        debtManagerAdminImpl = address(new DebtManagerAdmin(dataProvider));

        vm.stopBroadcast();
    }
}

contract RollbackCashbackUpgrade is GnosisHelpers, Utils, Test {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    
    address eventEmitter;
    address cashModule;
    address cashLens;
    address debtManager;
    address dataProvider;
    address cashbackDispatcher;
    address payable settlementDispatcherReap;
    address payable settlementDispatcherRain;

    address cashbackDispatcherImpl = 0x61064212482DB2369915849f2d8227a060f82680;
    address cashModuleCoreImpl = 0x453061CA8e5Aa517925203122feC84d0bf6c8a71;
    address cashModuleSettersImpl = 0x4076fB28b2854DEf471Ba46FF3c1Fae0683C7De8;
    address cashEventEmitterImpl = 0x60Bb4472e7AFF0699Dc8527503A784482fB82f50;
    address cashLensImpl = 0xD3F3480511FB25a3D86568B6e1eFBa09d0aDEebF;
    address settlementDispatcherReapImpl = 0x12A5b7C4F5978D67809F94D6a5D8D559102Bd975;
    address settlementDispatcherRainImpl = 0x3E662fa9d7e0Af805b8ab3083ee6f88e55536B7D;
    address debtManagerCoreImpl = 0x5c6d50cE0b8c401F9718c8C98272235E1c2BFaDc;
    address debtManagerAdminImpl = 0x8E87938C7FdF1d4728D87639e15E425A98a2d94F;

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
        cashLens = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashLens")
        );
        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        eventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        settlementDispatcherReap = payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        ));
        settlementDispatcherRain = payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherRain")
        ));

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        
        string memory upgradeCashbackDispatcher = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashbackDispatcherImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashbackDispatcher), upgradeCashbackDispatcher, "0", false)));
        
        string memory upgradeSettlementDispatcherReap = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherReapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), upgradeSettlementDispatcherReap, "0", false)));
        
        string memory upgradeSettlementDispatcherRain = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherRainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherRain), upgradeSettlementDispatcherRain, "0", false)));
        
        string memory upgradeDebtManager = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, debtManagerCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), upgradeDebtManager, "0", false)));
        
        string memory upgradeDebtManagerAdmin = iToHex(abi.encodeWithSelector(DebtManagerCore.setAdminImpl.selector, debtManagerAdminImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), upgradeDebtManagerAdmin, "0", false)));
        
        string memory upgradeCashModule = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCashModule, "0", false)));
        
        string memory upgradeCashModuleSetters = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCashModuleSetters, "0", false)));

        string memory upgradeCashEventEmitter = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(eventEmitter), upgradeCashEventEmitter, "0", false)));

        string memory upgradeCashLens = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashLensImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashLens), upgradeCashLens, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/RollbackCashbackUpgrade.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}

contract RedoCashbackUpgrade is GnosisHelpers, Utils, Test {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address scrToken = 0xd29687c813D741E2F938F4aC377128810E217b1b;
    
    address eventEmitter;
    address cashModule;
    address cashLens;
    address debtManager;
    address dataProvider;
    address cashbackDispatcher;
    address payable settlementDispatcherReap;
    address payable settlementDispatcherRain;

    address cashbackDispatcherImpl = 0xD0F3bd9fC0991BC8C2E61DeE70547BB707802105;
    address cashModuleCoreImpl = 0x41BDE792ef60866dD906213bA26b1F95Fc2633E6;
    address cashModuleSettersImpl = 0xf998E432fe547cD6b725e6A96Bd85b0b435AaFe0;
    address cashEventEmitterImpl = 0x37ffDB49BB28C71AF5eFB6dDAFFDA8BF535cBb69;
    address cashLensImpl = 0xeB3ae54aBf2744fc199c27e282eD30f139056e6D;
    address settlementDispatcherReapImpl = 0x28BFA29387C4CE5255632A5dBd39d347d4FC427b;
    address settlementDispatcherRainImpl = 0xB561CA2981E695895D34296015c03bDC079b94eF;
    address debtManagerCoreImpl = 0x1f17d9530447Fab071A8b3dAdDE1E0604483ca1B;
    address debtManagerAdminImpl = 0x7E1Ea03Cd263A785E557343C73eeA40fF17a8bA1;
    
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
        cashLens = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashLens")
        );
        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        eventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        settlementDispatcherReap = payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        ));
        settlementDispatcherRain = payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherRain")
        ));

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        
        string memory upgradeCashbackDispatcher = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashbackDispatcherImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashbackDispatcher), upgradeCashbackDispatcher, "0", false)));
        
        string memory upgradeSettlementDispatcherReap = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherReapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), upgradeSettlementDispatcherReap, "0", false)));
        
        string memory upgradeSettlementDispatcherRain = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherRainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherRain), upgradeSettlementDispatcherRain, "0", false)));
        
        string memory upgradeDebtManager = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, debtManagerCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), upgradeDebtManager, "0", false)));
        
        string memory upgradeDebtManagerAdmin = iToHex(abi.encodeWithSelector(DebtManagerCore.setAdminImpl.selector, debtManagerAdminImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), upgradeDebtManagerAdmin, "0", false)));
        
        string memory upgradeCashModule = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCashModule, "0", false)));
        
        string memory upgradeCashModuleSetters = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCashModuleSetters, "0", false)));

        string memory upgradeCashEventEmitter = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(eventEmitter), upgradeCashEventEmitter, "0", false)));

        string memory upgradeCashLens = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashLensImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashLens), upgradeCashLens, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/RedoCashbackUpgrade.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}