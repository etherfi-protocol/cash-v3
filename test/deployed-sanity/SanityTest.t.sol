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
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address etherFiWallet1 = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;
    address etherFiWallet2 = 0xB42833d6edd1241474D33ea99906fD4CBE893730;
    address topUpDepositor1 = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address topUpDepositor2 = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;
    address settlementDispatcherBridger = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address pauser = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address unpauser = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address[] topUpWallets;

    CashbackDispatcher cashbackDispatcher;
    IDebtManager debtManager;
    EtherFiDataProvider dataProvider;
    EtherFiHook hook;
    EtherFiSafeFactory safeFactory;
    CashEventEmitter eventEmitter;
    PriceProvider priceProvider;
    RoleRegistry roleRegistry;
    SettlementDispatcher settlementDispatcherReap;
    SettlementDispatcher settlementDispatcherRain;
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
        
        settlementDispatcherReap = SettlementDispatcher(payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        )));

        settlementDispatcherRain = SettlementDispatcher(payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherRain")
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

        topUpWallets.push(0xf96f8E03615f7b71e0401238D28bb08CceECBae7);
        topUpWallets.push(0xB82C61E4A4b4E5524376BC54013a154b2e55C5c8);
        topUpWallets.push(0xC73019F991dCBCc899d6B76000FdcCc99a208235);
        topUpWallets.push(0x93D540Dd6893bF9eA8ECD57fce32cB49b2D1B510);
        topUpWallets.push(0x29ebBC872CE1AF08508A65053b725Beadba43C48);
        topUpWallets.push(0x957a670ecE294dDf71c6A9C030432Db013082fd1);
        topUpWallets.push(0xFb5e703DAe21C594246f0311AE0361D1dFe250b1);
        topUpWallets.push(0xab00819212917dA43A81b696877Cc0BcA798b613);
        topUpWallets.push(0x5609BB231ec547C727D65eb6811CCd0C731339De);
        topUpWallets.push(0xcf1369d6CdD148AF5Af04F4002dee9A00c7F8Ae9);
    }

    function test_sanity_roles() public view {
        assertEq(roleRegistry.owner(), cashControllerSafe);
        assertTrue(roleRegistry.hasRole(roleRegistry.PAUSER(), pauser));
        assertTrue(roleRegistry.hasRole(roleRegistry.UNPAUSER(), unpauser));
        
        assertTrue(roleRegistry.hasRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet1));
        assertTrue(roleRegistry.hasRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet2));
        
        for (uint256 i = 0; i < topUpWallets.length; i++) {
            assertTrue(roleRegistry.hasRole(topUpDest.TOP_UP_ROLE(), topUpWallets[i]));
        }
        assertTrue(roleRegistry.hasRole(topUpDest.TOP_UP_DEPOSITOR_ROLE(), topUpDepositor1));
        assertTrue(roleRegistry.hasRole(topUpDest.TOP_UP_DEPOSITOR_ROLE(), topUpDepositor2));

        assertTrue(roleRegistry.hasRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), etherFiWallet1));
        assertTrue(roleRegistry.hasRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), etherFiWallet2));
        
        assertTrue(roleRegistry.hasRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(settlementDispatcherReap.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), settlementDispatcherBridger));
        assertTrue(roleRegistry.hasRole(settlementDispatcherRain.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), settlementDispatcherBridger));

        assertTrue(roleRegistry.hasRole(cashbackDispatcher.CASHBACK_DISPATCHER_ADMIN_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(debtManager.DEBT_MANAGER_ADMIN_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), cashControllerSafe));
        assertTrue(roleRegistry.hasRole(priceProvider.PRICE_PROVIDER_ADMIN_ROLE(), cashControllerSafe));
    }
}