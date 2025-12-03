// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { BinSponsor } from "../../src/interfaces/ICashModule.sol";

contract VerifySettlementDispatcherV2Bytecode is ContractCodeChecker, Test {
    // Deployed implementation addresses
    address constant NEW_CASH_MODULE_CORE_IMPL = 0x89943C6c7DA1246f614424f959411BBc9B4e7Aa9;
    address constant NEW_CASH_MODULE_SETTERS_IMPL = 0x4c5644c0BCD100263d28c4eB735f9143eC83847F;
    address constant NEW_CASH_EVENT_EMITTER_IMPL = 0x8124a19dB8fEae123187C0B6Eb214f8ab294F6e6;
    address constant SETTLEMENT_DISPATCHER_V2_IMPL = 0x8fF38032083C0E36C3CdC8c509758514Fe0a49E2;
    address constant SETTLEMENT_DISPATCHER_V2_PROXY = 0x2539031cD38e98317Cd246c8ED36F31117e6725b;
    address constant NEW_DEBT_MANAGER_CORE_IMPL = 0xa1C0F2e999EBfa91b8d0be2cC05A44223772896B;

    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant CASH_MODULE = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io";
        vm.createSelectFork(scrollRpc);
    }

    function test_settlementDispatcherV2_verifyBytecode() public {
        CashModuleCore localCashModuleCore = new CashModuleCore(DATA_PROVIDER);
        CashModuleSetters localCashModuleSetters = new CashModuleSetters(DATA_PROVIDER);
        CashEventEmitter localCashEventEmitter = new CashEventEmitter(CASH_MODULE);
        DebtManagerCore localDebtManagerCore = new DebtManagerCore(DATA_PROVIDER);
        SettlementDispatcherV2 localSettlementDispatcherV2 = new SettlementDispatcherV2(
            BinSponsor.CardOrder,
            DATA_PROVIDER
        );

        console.log("-------------- Cash Module Core ----------------");
        _verifyConstructorParameter(
            address(CashModuleCore(NEW_CASH_MODULE_CORE_IMPL).etherFiDataProvider()),
            DATA_PROVIDER,
            "CashModuleCore dataProvider"
        );

        emit log_named_address("Verifying contract", NEW_CASH_MODULE_CORE_IMPL);
        verifyContractByteCodeMatch(NEW_CASH_MODULE_CORE_IMPL, address(localCashModuleCore));

        console.log("-------------- Cash Module Setters ----------------");
        _verifyConstructorParameter(
            address(CashModuleSetters(NEW_CASH_MODULE_SETTERS_IMPL).etherFiDataProvider()),
            DATA_PROVIDER,
            "CashModuleSetters dataProvider"
        );

        emit log_named_address("Verifying contract", NEW_CASH_MODULE_SETTERS_IMPL);
        verifyContractByteCodeMatch(NEW_CASH_MODULE_SETTERS_IMPL, address(localCashModuleSetters));

        console.log("-------------- Cash Event Emitter ----------------");
        _verifyConstructorParameter(
            address(CashEventEmitter(NEW_CASH_EVENT_EMITTER_IMPL).cashModule()),
            CASH_MODULE,
            "CashEventEmitter cashModule"
        );
        emit log_named_address("Verifying contract", NEW_CASH_EVENT_EMITTER_IMPL);
        verifyContractByteCodeMatch(NEW_CASH_EVENT_EMITTER_IMPL, address(localCashEventEmitter));

        console.log("-------------- Debt Manager Core ----------------");
        _verifyConstructorParameter(
            address(DebtManagerCore(NEW_DEBT_MANAGER_CORE_IMPL).etherFiDataProvider()),
            DATA_PROVIDER,
            "DebtManagerCore dataProvider"
        );
        emit log_named_address("Verifying contract", NEW_DEBT_MANAGER_CORE_IMPL);
        verifyContractByteCodeMatch(NEW_DEBT_MANAGER_CORE_IMPL, address(localDebtManagerCore));

        console.log("-------------- Settlement Dispatcher V2 Implementation ----------------");
        SettlementDispatcherV2 deployedImpl = SettlementDispatcherV2(payable(SETTLEMENT_DISPATCHER_V2_IMPL));
        BinSponsor deployedBinSponsor = deployedImpl.binSponsor();
        address deployedDataProvider = address(deployedImpl.dataProvider());

        require(deployedBinSponsor == BinSponsor.CardOrder, "SettlementDispatcherV2 binSponsor mismatch");
        emit log_named_string("  binSponsor", "CardOrder");
        _verifyConstructorParameter(deployedDataProvider, DATA_PROVIDER, "SettlementDispatcherV2 dataProvider");

        emit log_named_address("Verifying contract", SETTLEMENT_DISPATCHER_V2_IMPL);
        verifyContractByteCodeMatch(payable(SETTLEMENT_DISPATCHER_V2_IMPL), payable(address(localSettlementDispatcherV2)));

        console.log("-------------- Settlement Dispatcher V2 Proxy ----------------");
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 proxyImplSlotValue = vm.load(SETTLEMENT_DISPATCHER_V2_PROXY, implementationSlot);
        address proxyImplementation = address(uint160(uint256(proxyImplSlotValue)));
        
        require(proxyImplementation == SETTLEMENT_DISPATCHER_V2_IMPL, "Proxy implementation address mismatch");
        emit log_named_address("  proxy points to", proxyImplementation);

        SettlementDispatcherV2 proxy = SettlementDispatcherV2(payable(SETTLEMENT_DISPATCHER_V2_PROXY));
        _verifyConstructorParameter(
            address(proxy.roleRegistry()),
            ROLE_REGISTRY,
            "SettlementDispatcherV2 proxy roleRegistry"
        );

        UUPSProxy localProxy = new UUPSProxy(address(localSettlementDispatcherV2), "");
        emit log_named_address("Verifying contract", SETTLEMENT_DISPATCHER_V2_PROXY);
        verifyContractByteCodeMatch(payable(SETTLEMENT_DISPATCHER_V2_PROXY), address(localProxy));
    }

    function _verifyConstructorParameter(address actual, address expected, string memory paramName) internal view {
        require(actual == expected, string.concat(paramName, " mismatch"));
    }
}

