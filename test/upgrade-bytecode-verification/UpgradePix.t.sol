// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore, BinSponsor } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";

contract UpgradePixVerifyBytecode is ContractCodeChecker, Test {
    address debtManagerCoreImpl = 0xD840daC5a5CEe82dC1a898a184A1Fa7E9Df97bf7;         
    address debtManagerAdminImpl = 0xef41ADB815A209073FC54A635aFC71eeB6341aBb;
    address cashModuleCoreImpl = 0xE9EE6923D41Cf5F964F11065436BD90D4577B5e4;    
    address cashModuleSettersImpl = 0x0052F731a6BEA541843385ffBA408F52B74Cb624;    
    address cashEventEmitterImpl = 0x8c370794f54F00f12580913E4456d377eA116984;
    address settlementDispatcherPixImpl = 0x1643507bCEa7FF94aCaFCc6Ac1d47F0DF3D137FE;

    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeMultispend_verifyBytecode() public {
        DebtManagerCore debtManagerCore = new DebtManagerCore(dataProvider);
        DebtManagerAdmin debtManagerAdmin = new DebtManagerAdmin(dataProvider);
        SettlementDispatcher settlementDispatcherPix = new SettlementDispatcher(BinSponsor.PIX, dataProvider);
        CashEventEmitter cashEventEmitter = new CashEventEmitter(cashModule);
        CashModuleCore cashModuleCore = new CashModuleCore(dataProvider);
        CashModuleSetters cashModuleSetters = new CashModuleSetters(dataProvider);

        console.log("-------------- Debt Manager ----------------");
        emit log_named_address("New deploy", address(debtManagerCore));
        emit log_named_address("Verifying contract", address(debtManagerCoreImpl));
        verifyContractByteCodeMatch(address(debtManagerCoreImpl), address(debtManagerCore));

        console.log("-------------- Debt Manager Admin ----------------");
        emit log_named_address("New deploy", address(debtManagerAdmin));
        emit log_named_address("Verifying contract", address(debtManagerAdminImpl));
        verifyContractByteCodeMatch(address(debtManagerAdminImpl), address(debtManagerAdmin));

        console.log("-------------- Settlement Dispatcher Pix ----------------");
        emit log_named_address("New deploy", address(settlementDispatcherPix));
        emit log_named_address("Verifying contract", address(settlementDispatcherPixImpl));
        verifyContractByteCodeMatch(address(settlementDispatcherPixImpl), address(settlementDispatcherPix));

        console.log("-------------- Cash Event Emitter ----------------");
        emit log_named_address("New deploy", address(cashEventEmitter));
        emit log_named_address("Verifying contract", address(cashEventEmitterImpl));
        verifyContractByteCodeMatch(address(cashEventEmitterImpl), address(cashEventEmitter));
     
        console.log("-------------- Cash Module Core ----------------");
        emit log_named_address("New deploy", address(cashModuleCore));
        emit log_named_address("Verifying contract", address(cashModuleCoreImpl));
        verifyContractByteCodeMatch(address(cashModuleCoreImpl), address(cashModuleCore));
     
        console.log("-------------- Cash Module Setters ----------------");
        emit log_named_address("New deploy", address(cashModuleSetters));
        emit log_named_address("Verifying contract", address(cashModuleSettersImpl));
        verifyContractByteCodeMatch(address(cashModuleSettersImpl), address(cashModuleSetters));
    }
}