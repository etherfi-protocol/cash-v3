// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.28;

// import { Test, console } from "forge-std/Test.sol";
// import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

// import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
// import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
// import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
// import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";


// contract UpgradeWithdrawalBugFixVerifyBytecode is ContractCodeChecker, Test {
//     address debtManagerCoreImpl = 0x5c6d50cE0b8c401F9718c8C98272235E1c2BFaDc;         
//     address cashEventEmitterImpl = 0x60Bb4472e7AFF0699Dc8527503A784482fB82f50;    
//     address cashModuleSettersImpl = 0x4076fB28b2854DEf471Ba46FF3c1Fae0683C7De8;    
//     address cashModuleCoreImpl = 0x453061CA8e5Aa517925203122feC84d0bf6c8a71;    
//     address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
//     address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;

//     function setUp() public {
//         string memory scrollRpc = vm.envString("SCROLL_RPC");
//         if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
//         vm.createSelectFork(scrollRpc);
//     }

//     function test_upgradeWithdrawalBugFix_verifyBytecode() public {
//         DebtManagerCore debtManagerCore = new DebtManagerCore(dataProvider);
//         CashEventEmitter cashEventEmitter = new CashEventEmitter(cashModule);
//         CashModuleCore cashModuleCore = new CashModuleCore(dataProvider);
//         CashModuleSetters cashModuleSetters = new CashModuleSetters(dataProvider);

//         console.log("-------------- Debt Manager ----------------");
//         emit log_named_address("New deploy", address(debtManagerCore));
//         emit log_named_address("Verifying contract", address(debtManagerCoreImpl));
//         verifyContractByteCodeMatch(address(debtManagerCoreImpl), address(debtManagerCore));
     
//         console.log("-------------- Cash Event Emitter ----------------");
//         emit log_named_address("New deploy", address(cashEventEmitter));
//         emit log_named_address("Verifying contract", address(cashEventEmitterImpl));
//         verifyContractByteCodeMatch(address(cashEventEmitterImpl), address(cashEventEmitter));
     
//         console.log("-------------- Cash Module Core ----------------");
//         emit log_named_address("New deploy", address(cashModuleCore));
//         emit log_named_address("Verifying contract", address(cashModuleCoreImpl));
//         verifyContractByteCodeMatch(address(cashModuleCoreImpl), address(cashModuleCore));
     
//         console.log("-------------- Cash Module Setters ----------------");
//         emit log_named_address("New deploy", address(cashModuleSetters));
//         emit log_named_address("Verifying contract", address(cashModuleSettersImpl));
//         verifyContractByteCodeMatch(address(cashModuleSettersImpl), address(cashModuleSetters));
//     }
// }