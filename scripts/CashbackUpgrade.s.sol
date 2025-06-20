// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../src/debt-manager/DebtManagerAdmin.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../src/modules/cash/CashLens.sol";
import { CashModuleCore, BinSponsor } from "../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { SettlementDispatcher } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { UUPSProxy } from "../src/UUPSProxy.sol";

import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { TopUpDestNativeGateway } from "../src/top-up/TopUpDestNativeGateway.sol";

import { GnosisHelpers } from "./utils/GnosisHelpers.sol";
import { Utils } from "./utils/Utils.sol";

contract CashbackUpgrade is GnosisHelpers, Utils, Test {
    address scrToken = 0xd29687c813D741E2F938F4aC377128810E217b1b;

    address eventEmitter;
    address cashModule;
    address cashLens;
    address debtManager;
    address dataProvider;
    address cashbackDispatcher;
    address payable settlementDispatcherReap;
    address payable settlementDispatcherRain;

    function run() public {
        string memory deployments = readDeploymentFile();

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

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address cashbackDispatcherImpl = address(new CashbackDispatcher(dataProvider));
        address cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        address cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        address cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        address cashLensImpl = address(new CashLens(cashModule, dataProvider));
        address settlementDispatcherReapImpl = payable(address(new SettlementDispatcher(BinSponsor.Reap, dataProvider)));
        address settlementDispatcherRainImpl = payable(address(new SettlementDispatcher(BinSponsor.Rain, dataProvider)));
        address debtManagerCoreImpl = address(new DebtManagerCore(dataProvider));
        address debtManagerAdminImpl = address(new DebtManagerAdmin(dataProvider));

        address[] memory tokens = new address[](1);
        tokens[0] = address(scrToken);

        bool[] memory isCashbackToken = new bool[](1);
        isCashbackToken[0] = true;

        UUPSUpgradeable(cashbackDispatcher).upgradeToAndCall(cashbackDispatcherImpl, "");
        UUPSUpgradeable(settlementDispatcherReap).upgradeToAndCall(settlementDispatcherReapImpl, "");
        UUPSUpgradeable(settlementDispatcherRain).upgradeToAndCall(settlementDispatcherRainImpl, "");
        UUPSUpgradeable(debtManager).upgradeToAndCall(debtManagerCoreImpl, "");
        DebtManagerCore(debtManager).setAdminImpl(debtManagerAdminImpl);

        UUPSUpgradeable(cashModule).upgradeToAndCall(cashModuleCoreImpl, "");
        CashModuleCore(cashModule).setCashModuleSettersAddress(cashModuleSettersImpl);

        UUPSUpgradeable(eventEmitter).upgradeToAndCall(cashEventEmitterImpl, "");
        UUPSUpgradeable(cashLens).upgradeToAndCall(cashLensImpl, "");

        CashbackDispatcher(cashbackDispatcher).configureCashbackToken(tokens, isCashbackToken);
    }   
}

contract RollbackUpgrade is Utils, Test {
    address cashbackDispatcherImpl = 0xbDb996BdcF019F98E34E5cBb9Aa8b02DB5191eE4;
    address cashModuleCoreImpl = 0x97B00ba19d608111Ffda2Aef12c3efFc30B00268;
    address cashModuleSettersImpl = 0x9f4Ac4ABB8476312Ced65959E7483d8a45de1B2C;
    address cashEventEmitterImpl = 0xed53192FF137ED38B64A4361D2e7094b0277e788;
    address cashLensImpl = 0x09DEf64C9938A68921dF8A547eF49950935e7618;
    address settlementDispatcherReapImpl = 0x9b54e3cfE6a6aD284809fA50d6E4F96c6dd43612;
    address settlementDispatcherRainImpl = 0xAc7F3d07297F5c2280dD3B9022Dbb4512Bf16921;
    address debtManagerCoreImpl = 0x6e41579D9dC38a829eF2899D7214b2e4940474ab;
    address debtManagerAdminImpl = 0x65B6Ede2A0c31AD19f86642Baa3213b3Bf890811;

    address eventEmitter;
    address cashModule;
    address cashLens;
    address debtManager;
    address dataProvider;
    address cashbackDispatcher;
    address payable settlementDispatcherReap;
    address payable settlementDispatcherRain;

    function run() public {
        string memory deployments = readDeploymentFile();

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

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        UUPSUpgradeable(cashbackDispatcher).upgradeToAndCall(cashbackDispatcherImpl, "");
        UUPSUpgradeable(settlementDispatcherReap).upgradeToAndCall(settlementDispatcherReapImpl, "");
        UUPSUpgradeable(settlementDispatcherRain).upgradeToAndCall(settlementDispatcherRainImpl, "");
        UUPSUpgradeable(debtManager).upgradeToAndCall(debtManagerCoreImpl, "");
        DebtManagerCore(debtManager).setAdminImpl(debtManagerAdminImpl);

        UUPSUpgradeable(cashModule).upgradeToAndCall(cashModuleCoreImpl, "");
        CashModuleCore(cashModule).setCashModuleSettersAddress(cashModuleSettersImpl);

        UUPSUpgradeable(eventEmitter).upgradeToAndCall(cashEventEmitterImpl, "");
        UUPSUpgradeable(cashLens).upgradeToAndCall(cashLensImpl, "");
    }   
}