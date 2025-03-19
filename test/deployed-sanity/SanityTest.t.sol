// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { AaveV3Module } from "../../src/modules/aave-v3/AaveV3Module.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { Utils } from "../utils/Utils.sol";

contract SanityTest is Utils {
    address cashControllerSafe = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address safeDeployer = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address etherFiWallet1 = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address etherFiWallet2 = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address topUpWallet1 = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address topUpWallet2 = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address topUpDepositor = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address settlementDispatcherBridger = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address pauser = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address unpauser = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    CashbackDispatcher cashbackDispatcher;
    IDebtManager debtManager;
    EtherFiDataProvider dataProvider;
    EtherFiHook hook;
    EtherFiSafeFactory safeFactory;
    CashEventEmitter eventEmitter;
    PriceProvider priceProvider;
    RoleRegistry roleRegistry;
    SettlementDispatcher settlementDispatcher;
    TopUpDest topUpDest;
    ICashModule cashModule;
    CashLens cashLens;
    OpenOceanSwapModule openOceanSwapModule;

    function setUp() public {
        string memory rpc = vm.envString("SCROLL_RPC");
        if (bytes(rpc).length == 0) rpc = "https//rpc.scroll.io";

        vm.createSelectFork(rpc);

        string memory deployments = readDeploymentFile();

        cashbackDispatcher = CashbackDispatcher(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashbackDispatcher")
        ));
        
        debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));
        
        dataProvider = EtherFiDataProvider(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        ));
        
        hook = EtherFiHook(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiHook")
        ));
        
        safeFactory = EtherFiSafeFactory(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiSafeFactory")
        ));
        
        eventEmitter = CashEventEmitter(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        ));
        
        priceProvider = PriceProvider(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        ));
        
        roleRegistry = RoleRegistry(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        ));
        
        settlementDispatcher = SettlementDispatcher(payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcher")
        )));
        
        topUpDest = TopUpDest(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpDest")
        ));
        
        cashModule = ICashModule(stdJson.readAddress(
            deployments, 
            string.concat(".", "addresses", ".", "CashModule")
        ));

        cashLens = CashLens(stdJson.readAddress(
            deployments, 
            string.concat(".", "addresses", ".", "CashLens")
        ));

        openOceanSwapModule = OpenOceanSwapModule(stdJson.readAddress(
            deployments, 
            string.concat(".", "addresses", ".", "OpenOceanSwapModule")
        ));
    }

    function test_sanity_roles() public view {
        assertEq(roleRegistry.owner(), cashControllerSafe);
        assertTrue(roleRegistry.hasRole(roleRegistry.PAUSER(), pauser));
        assertTrue(roleRegistry.hasRole(roleRegistry.UNPAUSER(), unpauser));
        
        assertTrue(roleRegistry.hasRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet1));
        assertTrue(roleRegistry.hasRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet2));
        
        assertTrue(roleRegistry.hasRole(topUpDest.TOP_UP_ROLE(), topUpWallet1));
        assertTrue(roleRegistry.hasRole(topUpDest.TOP_UP_ROLE(), topUpWallet2));
        assertTrue(roleRegistry.hasRole(topUpDest.TOP_UP_DEPOSITOR_ROLE(), topUpDepositor));

        assertTrue(roleRegistry.hasRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), safeDeployer));
        
        assertTrue(roleRegistry.hasRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(settlementDispatcher.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), settlementDispatcherBridger));

        assertTrue(roleRegistry.hasRole(cashbackDispatcher.CASHBACK_DISPATCHER_ADMIN_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(debtManager.DEBT_MANAGER_ADMIN_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(priceProvider.PRICE_PROVIDER_ADMIN_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(topUpDest.TOP_UP_ROLE(), cashControllerSafe));
    }
}