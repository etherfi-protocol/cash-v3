// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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

contract DeployCashModule is Utils {
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

        string memory deployments = readDeploymentFile();

        dataProvider = EtherFiDataProvider(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        ));

        roleRegistry = RoleRegistry(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        ));

        EtherFiSafe safe = EtherFiSafe(0xaE663e85c97402d56000C6E21Cc770fDEc02b5c8);

        address newDataProviderImpl = address(new EtherFiDataProvider());
        UUPSUpgradeable(address(dataProvider)).upgradeToAndCall(newDataProviderImpl, "");

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


        address[] memory modules = new address[](1);
        modules[0] = address(cashModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        dataProvider.configureModules(modules, shouldWhitelist);
        dataProvider.setCashModule(address(cashModule));
        dataProvider.setCashLens(address(cashLens));

        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = abi.encode(10000e6, 100000e6, -4 * 3600);

        configureModules(deployerPrivateKey, safe, modules, shouldWhitelist, moduleSetupData);

        vm.stopBroadcast();
    }

    function configureModules(uint256 ownerPrivateKey, EtherFiSafe safe, address[] memory modules, bool[] memory shouldWhitelist, bytes[] memory moduleSetupData) internal {
        address[] memory signers = new address[](1);
        signers[0] = vm.addr(ownerPrivateKey);

        bytes[] memory signatures = new bytes[](1);

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), keccak256(abi.encode(moduleSetupData)), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digestHash);
        signatures[0] = abi.encodePacked(r, s, v);

        safe.configureModules(modules, shouldWhitelist, moduleSetupData, signers, signatures);

    }
}