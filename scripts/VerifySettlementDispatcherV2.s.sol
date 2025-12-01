// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { CashModuleCore } from "../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { UUPSProxy } from "../src/UUPSProxy.sol";
import { BinSponsor } from "../src/interfaces/ICashModule.sol";
import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";
import { Utils } from "./utils/Utils.sol";

contract VerifySettlementDispatcherV2 is Script, Utils, ContractCodeChecker {
    // Hardcoded deployed addresses
    address internal constant NEW_CASH_MODULE_CORE_IMPL = 0x89943C6c7DA1246f614424f959411BBc9B4e7Aa9;
    address internal constant NEW_CASH_MODULE_SETTERS_IMPL = 0x4c5644c0BCD100263d28c4eB735f9143eC83847F;
    address internal constant NEW_CASH_EVENT_EMITTER_IMPL = 0x8124a19dB8fEae123187C0B6Eb214f8ab294F6e6;
    address internal constant SETTLEMENT_DISPATCHER_V2_IMPL = 0x8fF38032083C0E36C3CdC8c509758514Fe0a49E2;
    address internal constant SETTLEMENT_DISPATCHER_V2_PROXY = 0x2539031cD38e98317Cd246c8ED36F31117e6725b;

    function run() public {
        string memory deployments = readDeploymentFile();
        
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        console2.log("Deployed addresses:");
        console2.log("  CashModuleCore:", NEW_CASH_MODULE_CORE_IMPL);
        console2.log("  CashModuleSetters:", NEW_CASH_MODULE_SETTERS_IMPL);
        console2.log("  CashEventEmitter:", NEW_CASH_EVENT_EMITTER_IMPL);
        console2.log("  SettlementDispatcherV2 Impl:", SETTLEMENT_DISPATCHER_V2_IMPL);
        console2.log("  SettlementDispatcherV2 Proxy:", SETTLEMENT_DISPATCHER_V2_PROXY);

        // Deploy contracts locally with same constructor parameters
        console2.log("\nDeploying contracts locally...");
        CashModuleCore localCashModuleCore = new CashModuleCore(dataProvider);
        CashModuleSetters localCashModuleSetters = new CashModuleSetters(dataProvider);
        CashEventEmitter localCashEventEmitter = new CashEventEmitter(cashModule);
        SettlementDispatcherV2 localSettlementDispatcherV2 = new SettlementDispatcherV2(
            BinSponsor.CardOrder,
            dataProvider
        );

        // Verify constructor parameters match
        console2.log("\n=== Verifying Constructor Parameters for new Impls ===");
        verifyConstructorParameters(dataProvider, cashModule, roleRegistry);

        // Verify bytecode matches
        console2.log("\n=== Verifying bytecode matches for new Impls ===");
        verifyContractByteCodeMatch(NEW_CASH_MODULE_CORE_IMPL, address(localCashModuleCore));
        verifyContractByteCodeMatch(NEW_CASH_MODULE_SETTERS_IMPL, address(localCashModuleSetters));
        verifyContractByteCodeMatch(NEW_CASH_EVENT_EMITTER_IMPL, address(localCashEventEmitter));

        console2.log("\n=== Verifying Constructor and Bytecode for new contract: SettlementDispatcherV2 ===");
        verifySettlementDispatcherV2(dataProvider, roleRegistry, address(localSettlementDispatcherV2));
    }

    function verifyConstructorParameters(address expectedDataProvider, address expectedCashModule, address expectedRoleRegistry) internal view {
        address deployedCashModuleCoreDataProvider = address(CashModuleCore(NEW_CASH_MODULE_CORE_IMPL).etherFiDataProvider());
        address deployedCashModuleSettersDataProvider = address(CashModuleSetters(NEW_CASH_MODULE_SETTERS_IMPL).etherFiDataProvider());
        address deployedCashEventEmitterCashModule = address(CashEventEmitter(NEW_CASH_EVENT_EMITTER_IMPL).cashModule());

        require(deployedCashModuleCoreDataProvider == expectedDataProvider, "CashModuleCore dataProvider mismatch");
        require(deployedCashModuleSettersDataProvider == expectedDataProvider, "CashModuleSetters dataProvider mismatch");
        require(deployedCashEventEmitterCashModule == expectedCashModule, "CashEventEmitter cashModule mismatch");
        console2.log("Constructor parameters verified successfully");
    }

    function verifySettlementDispatcherV2(address expectedDataProvider, address expectedRoleRegistry, address localImpl) public  {
        SettlementDispatcherV2 deployedImpl = SettlementDispatcherV2(payable(SETTLEMENT_DISPATCHER_V2_IMPL));
        BinSponsor deployedBinSponsor = deployedImpl.binSponsor();
        address deployedDataProvider = address(deployedImpl.dataProvider());

        require(deployedBinSponsor == BinSponsor.CardOrder, "SettlementDispatcherV2 binSponsor mismatch");
        require(deployedDataProvider == expectedDataProvider, "SettlementDispatcherV2 dataProvider mismatch");
        console2.log("SettlementDispatcherV2 implementation constructor parameters verified");

        verifyContractByteCodeMatch(payable(SETTLEMENT_DISPATCHER_V2_IMPL), payable(localImpl));

        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 proxyImplSlotValue = vm.load(SETTLEMENT_DISPATCHER_V2_PROXY, implementationSlot);
        address proxyImplementation = address(uint160(uint256(proxyImplSlotValue)));
        
        require(proxyImplementation == SETTLEMENT_DISPATCHER_V2_IMPL, "Proxy implementation address mismatch");
        console2.log("SettlementDispatcherV2 proxy implementation verified");

        SettlementDispatcherV2 proxy = SettlementDispatcherV2(payable(SETTLEMENT_DISPATCHER_V2_PROXY));
        address proxyRoleRegistry = address(proxy.roleRegistry());
        require(proxyRoleRegistry == expectedRoleRegistry, "SettlementDispatcherV2 proxy roleRegistry mismatch");
        console2.log("SettlementDispatcherV2 proxy initialization verified");

        UUPSProxy localProxy = deployLocalProxy(localImpl, expectedRoleRegistry);
        verifyContractByteCodeMatch(payable(SETTLEMENT_DISPATCHER_V2_PROXY), address(localProxy));
        console2.log("SettlementDispatcherV2 proxy bytecode verified");
    }

        function deployLocalProxy(address impl, address roleRegistry) internal returns (UUPSProxy) {
        address[] memory tokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](0);
        
        return new UUPSProxy(
            impl,
            abi.encodeWithSelector(
                SettlementDispatcherV2.initialize.selector,
                roleRegistry,
                tokens,
                destDatas
            )
        );
    }
}

