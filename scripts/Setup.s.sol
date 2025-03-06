// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import {TopUpDest} from "../src/top-up/TopUpDest.sol";
import {RoleRegistry} from "../src/role-registry/RoleRegistry.sol";
import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";
import {EtherFiSafe} from "../src/safe/EtherFiSafe.sol";
import {EtherFiSafeFactory} from "../src/safe/EtherFiSafeFactory.sol";
import {EtherFiHook} from "../src/hook/EtherFiHook.sol";
import {ICashModule} from "../src/interfaces/ICashModule.sol";
import {AaveV3Module} from "../src/modules/aave-v3/AaveV3Module.sol";
import {CashLens} from "../src/modules/cash/CashLens.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";
import {IDebtManager} from "../src/interfaces/IDebtManager.sol";
import {ICashbackDispatcher} from "../src/interfaces/ICashbackDispatcher.sol";
import {IPriceProvider} from "../src/interfaces/IPriceProvider.sol";
import {ICashEventEmitter} from "../src/interfaces/ICashEventEmitter.sol";
import {CashModuleSetters} from "../src/modules/cash/CashModuleSetters.sol";
import {CashModuleCore} from "../src/modules/cash/CashModuleCore.sol";

contract Setup is Utils {
    EtherFiSafeFactory safeFactory;
    EtherFiDataProvider dataProvider;
    RoleRegistry roleRegistry;
    EtherFiHook hook;
    TopUpDest topUpDest;
    AaveV3Module aaveModule;
    ICashModule cashModule;
    CashLens cashLens;

    IDebtManager debtManager = IDebtManager(0x8f9d2Cd33551CE06dD0564Ba147513F715c2F4a0);
    ICashbackDispatcher cashbackDispatcher = ICashbackDispatcher(0x7d372C3ca903CA2B6ecd8600D567eb6bAfC5e6c9);
    IPriceProvider priceProvider = IPriceProvider(0x8B4C8c403fc015C46061A8702799490FD616E3bf);
    ICashEventEmitter cashEventEmitter = ICashEventEmitter(0x5423885B376eBb4e6104b8Ab1A908D350F6A162e);
    address settlementDispatcher = 0x4Dca5093E0bB450D7f7961b5Df0A9d4c24B24786;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        ChainConfig memory chainConfig = getChainConfig(vm.toString(block.chainid));

        address owner = chainConfig.owner;

        address dataProviderImpl = address(new EtherFiDataProvider{salt: getSalt(ETHER_FI_DATA_PROVIDER_IMPL)}());
        dataProvider = EtherFiDataProvider(address(new UUPSProxy{salt: getSalt(ETHER_FI_DATA_PROVIDER_PROXY)}(dataProviderImpl, "")));

        address roleRegistryImpl = address(new RoleRegistry{salt: getSalt(ROLE_REGISTRY_IMPL)}(address(dataProvider)));
        roleRegistry = RoleRegistry(address(new UUPSProxy{salt: getSalt(ROLE_REGISTRY_PROXY)}(roleRegistryImpl, "")));
        roleRegistry.initialize(owner);
        
        roleRegistry.grantRole(roleRegistry.PAUSER(), owner);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), owner);
        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), owner);

        aaveModule = new AaveV3Module{salt: getSalt(AAVE_MODULE)}(chainConfig.aaveV3Pool, address(dataProvider));

        address cashModuleSettersImpl = address(new CashModuleSetters(address(dataProvider)));
        address cashModuleCoreImpl = address(new CashModuleCore(address(dataProvider)));
        cashModule = ICashModule(address(new UUPSProxy(cashModuleCoreImpl, "")));
        cashModule.initialize(
            address(roleRegistry), 
            address(debtManager), 
            settlementDispatcher, 
            address(cashbackDispatcher), 
            address(cashEventEmitter),
            cashModuleSettersImpl
        );

        address cashLensImpl = address(new CashLens(address(cashModule), address(dataProvider)));
        cashLens = CashLens(address(new UUPSProxy(cashLensImpl, "")));
        cashLens.initialize(address(roleRegistry));

        roleRegistry.grantRole(cashModule.ETHER_FI_WALLET_ROLE(), owner);
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), owner);

        address hookImpl = address(new EtherFiHook{salt: getSalt(ETHER_FI_HOOK_IMPL)}(address(dataProvider)));
        hook = EtherFiHook(address(new UUPSProxy{salt: getSalt(ETHER_FI_HOOK_PROXY)}(hookImpl, "")));
        hook.initialize(address(roleRegistry));

        address safeImpl = CREATE3.deployDeterministic(abi.encodePacked(type(EtherFiSafe).creationCode, abi.encode(address(dataProvider))), getSalt(ETHER_FI_SAFE_IMPL));
        address safeFactoryImpl = CREATE3.deployDeterministic(abi.encodePacked(type(EtherFiSafeFactory).creationCode, ""), getSalt(ETHER_FI_SAFE_FACTORY_IMPL));
        address safeFactoryProxy = CREATE3.deployDeterministic(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(safeFactoryImpl, "")), getSalt(ETHER_FI_SAFE_FACTORY_PROXY));
        safeFactory = EtherFiSafeFactory(safeFactoryProxy);
        safeFactory.initialize(address(roleRegistry), safeImpl);

        address[] memory modules = new address[](2);
        modules[0] = address(aaveModule);
        modules[1] = address(cashModule);

        dataProvider.initialize(
            address(roleRegistry), 
            address(cashModule), 
            address(cashLens), 
            modules, 
            address(hook), 
            address(safeFactory), 
            address(priceProvider)
        );

        roleRegistry.grantRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), owner);

        address topUpDestImpl = address(new TopUpDest{salt: getSalt(TOP_UP_DEST_IMPL)}());
        topUpDest = TopUpDest(address(new UUPSProxy{salt: getSalt(TOP_UP_DEST_PROXY)}(topUpDestImpl, "")));
        topUpDest.initialize(address(roleRegistry), address(dataProvider));

        string memory parentObject = "parent object";

        string memory deployedAddresses = "addresses";

        vm.serializeAddress(deployedAddresses, "RoleRegistry", address(roleRegistry));
        vm.serializeAddress(deployedAddresses, "EtherFiDataProvider", address(dataProvider));
        vm.serializeAddress(deployedAddresses, "TopUpDest", address(topUpDest));
        vm.serializeAddress(deployedAddresses, "EtherFiSafeFactory", address(safeFactory));
        vm.serializeAddress(deployedAddresses, "EtherFiHook", address(hook));
        vm.serializeAddress(deployedAddresses, "DebtManager", address(debtManager));
        vm.serializeAddress(deployedAddresses, "EventEmitter", address(cashEventEmitter));
        vm.serializeAddress(deployedAddresses, "PriceProvider", address(priceProvider));
        vm.serializeAddress(deployedAddresses, "CashbackDispatcher", address(cashbackDispatcher));
        string memory addressOutput = vm.serializeAddress(deployedAddresses, "SettlementDispatcher", address(settlementDispatcher));
        string memory finalJson = vm.serializeString(
            parentObject,
            deployedAddresses,
            addressOutput
        );

        writeDeploymentFile(finalJson);

        vm.stopBroadcast();
    }
}