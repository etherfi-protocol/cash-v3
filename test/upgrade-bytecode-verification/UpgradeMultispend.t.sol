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
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";


contract UpgradeMultispendVerifyBytecode is ContractCodeChecker, Test {
    address debtManagerCoreImpl = 0x87f2304320B7ca0926071297c2f85932daad2234;         
    address settlementDispatcherRainImpl = 0xaf55EC4dE8f436751D638a91Da157771C29Fa15D;
    address settlementDispatcherReapImpl = 0x71f9D57D3e3a187e567b138C3229663a017397f4;
    address cashLensImpl = 0x9d0d3392D6a27323b8f46cEAe371de264c55ff70;    
    address cashEventEmitterImpl = 0x72CEc7C0Bd0a1401A17A07DdCBD92c561d424fE4;    
    address cashModuleSettersImpl = 0x4f7fF69964D58DC17C77b3C9BFc17d4f611BC62b;    
    address cashModuleCoreImpl = 0x6c39121123C6Ea69e2aa38Bef901FA075cC2d9Ca;    

    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeMultispend_verifyBytecode() public {
        DebtManagerCore debtManagerCore = new DebtManagerCore(dataProvider);
        SettlementDispatcher settlementDispatcherRain = new SettlementDispatcher(BinSponsor.Rain);
        SettlementDispatcher settlementDispatcherReap = new SettlementDispatcher(BinSponsor.Reap);
        CashLens cashLens = new CashLens(cashModule, dataProvider);
        CashEventEmitter cashEventEmitter = new CashEventEmitter(cashModule);
        CashModuleCore cashModuleCore = new CashModuleCore(dataProvider);
        CashModuleSetters cashModuleSetters = new CashModuleSetters(dataProvider);

        console.log("-------------- Debt Manager ----------------");
        emit log_named_address("New deploy", address(debtManagerCore));
        emit log_named_address("Verifying contract", address(debtManagerCoreImpl));
        verifyContractByteCodeMatch(address(debtManagerCoreImpl), address(debtManagerCore));
     
        console.log("-------------- Settlement Dispatcher Rain ----------------");
        emit log_named_address("New deploy", address(settlementDispatcherRain));
        emit log_named_address("Verifying contract", address(settlementDispatcherRainImpl));
        verifyContractByteCodeMatch(address(settlementDispatcherRainImpl), address(settlementDispatcherRain));
     
        console.log("-------------- Settlement Dispatcher Reap ----------------");
        emit log_named_address("New deploy", address(settlementDispatcherReap));
        emit log_named_address("Verifying contract", address(settlementDispatcherReapImpl));
        verifyContractByteCodeMatch(address(settlementDispatcherReapImpl), address(settlementDispatcherReap));
     
        console.log("-------------- Cash Lens ----------------");
        emit log_named_address("New deploy", address(cashLens));
        emit log_named_address("Verifying contract", address(cashLensImpl));
        verifyContractByteCodeMatch(address(cashLensImpl), address(cashLens));
     
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