// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
// import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

// import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
// import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
// import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
// import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
// import { CashLens } from "../../src/modules/cash/CashLens.sol";
// import { CashModuleCore, BinSponsor } from "../../src/modules/cash/CashModuleCore.sol";
// import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
// import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";

// contract UpgradeCashbackBytecodeCheck is ContractCodeChecker, Test {
//     address cashbackDispatcherImpl = 0xD0F3bd9fC0991BC8C2E61DeE70547BB707802105;
//     address cashModuleCoreImpl = 0x41BDE792ef60866dD906213bA26b1F95Fc2633E6;
//     address cashModuleSettersImpl = 0xf998E432fe547cD6b725e6A96Bd85b0b435AaFe0;
//     address cashEventEmitterImpl = 0x37ffDB49BB28C71AF5eFB6dDAFFDA8BF535cBb69;
//     address cashLensImpl = 0xeB3ae54aBf2744fc199c27e282eD30f139056e6D;
//     address settlementDispatcherReapImpl = 0x28BFA29387C4CE5255632A5dBd39d347d4FC427b;
//     address settlementDispatcherRainImpl = 0xB561CA2981E695895D34296015c03bDC079b94eF;
//     address debtManagerCoreImpl = 0x1f17d9530447Fab071A8b3dAdDE1E0604483ca1B;
//     address debtManagerAdminImpl = 0x7E1Ea03Cd263A785E557343C73eeA40fF17a8bA1;

//     address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
//     address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;


//     function setUp() public {
//         string memory scrollRpc = vm.envString("SCROLL_RPC");
//         if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
//         vm.createSelectFork(scrollRpc);
//     }

//     function test_upgradeCashback_verifyBytecode() public {
//         address cashbackDispatcherNewDeploy = address(new CashbackDispatcher(dataProvider));
//         address cashModuleCoreNewDeploy = address(new CashModuleCore(dataProvider));
//         address cashModuleSettersNewDeploy = address(new CashModuleSetters(dataProvider));
//         address cashEventEmitterNewDeploy = address(new CashEventEmitter(cashModule));
//         address cashLensNewDeploy = address(new CashLens(cashModule, dataProvider));
//         address settlementDispatcherReapNewDeploy = payable(address(new SettlementDispatcher(BinSponsor.Reap, dataProvider)));
//         address settlementDispatcherRainNewDeploy = payable(address(new SettlementDispatcher(BinSponsor.Rain, dataProvider)));
//         address debtManagerCoreNewDeploy = address(new DebtManagerCore(dataProvider));
//         address debtManagerAdminNewDeploy = address(new DebtManagerAdmin(dataProvider));

//         console.log("-------------- Cashback Dispatcher ----------------");
//         emit log_named_address("New deploy", address(cashbackDispatcherNewDeploy));
//         emit log_named_address("Verifying contract", address(cashbackDispatcherImpl));
//         verifyContractByteCodeMatch(address(cashbackDispatcherImpl), address(cashbackDispatcherNewDeploy));
        
//         console.log("-------------- Cash Module Core ----------------");
//         emit log_named_address("New deploy", address(cashModuleCoreNewDeploy));
//         emit log_named_address("Verifying contract", address(cashModuleCoreImpl));
//         verifyContractByteCodeMatch(address(cashModuleCoreImpl), address(cashModuleCoreNewDeploy));
        
//         console.log("-------------- Cash Module Setters ----------------");
//         emit log_named_address("New deploy", address(cashModuleSettersNewDeploy));
//         emit log_named_address("Verifying contract", address(cashModuleSettersImpl));
//         verifyContractByteCodeMatch(address(cashModuleSettersImpl), address(cashModuleSettersNewDeploy));
        
//         console.log("-------------- Cash Event Emitter ----------------");
//         emit log_named_address("New deploy", address(cashEventEmitterNewDeploy));
//         emit log_named_address("Verifying contract", address(cashEventEmitterImpl));
//         verifyContractByteCodeMatch(address(cashEventEmitterImpl), address(cashEventEmitterNewDeploy));
        
//         console.log("-------------- Cash Lens ----------------");
//         emit log_named_address("New deploy", address(cashLensNewDeploy));
//         emit log_named_address("Verifying contract", address(cashLensImpl));
//         verifyContractByteCodeMatch(address(cashLensImpl), address(cashLensNewDeploy));
     
//         console.log("-------------- Settlement Dispatcher Reap ----------------");
//         emit log_named_address("New deploy", address(settlementDispatcherReapNewDeploy));
//         emit log_named_address("Verifying contract", address(settlementDispatcherReapImpl));
//         verifyContractByteCodeMatch(address(settlementDispatcherReapImpl), address(settlementDispatcherReapNewDeploy));

//         console.log("-------------- Settlement Dispatcher Rain ----------------");
//         emit log_named_address("New deploy", address(settlementDispatcherRainNewDeploy));
//         emit log_named_address("Verifying contract", address(settlementDispatcherRainImpl));
//         verifyContractByteCodeMatch(address(settlementDispatcherRainImpl), address(settlementDispatcherRainNewDeploy));

//         console.log("-------------- Debt Manager Core ----------------");
//         emit log_named_address("New deploy", address(debtManagerCoreNewDeploy));
//         emit log_named_address("Verifying contract", address(debtManagerCoreImpl));
//         verifyContractByteCodeMatch(address(debtManagerCoreImpl), address(debtManagerCoreNewDeploy));
        
//         console.log("-------------- Debt Manager Admin ----------------");
//         emit log_named_address("New deploy", address(debtManagerAdminNewDeploy));
//         emit log_named_address("Verifying contract", address(debtManagerAdminImpl));
//         verifyContractByteCodeMatch(address(debtManagerAdminImpl), address(debtManagerAdminNewDeploy));
//     }
// }