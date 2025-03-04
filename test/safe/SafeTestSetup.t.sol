// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IModule } from "../../src/interfaces/IModule.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { ICashbackDispatcher } from "../../src/interfaces/ICashbackDispatcher.sol";
import { IPriceProvider } from "../../src/interfaces/IPriceProvider.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModule } from "../../src/modules/cash/CashModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";

contract SafeTestSetup is Test {
    using MessageHashUtils for bytes32;

    EtherFiSafeFactory public safeFactory;
    EtherFiSafe public safe;
    EtherFiDataProvider public dataProvider;
    RoleRegistry public roleRegistry;
    EtherFiHook public hook;

    IDebtManager debtManager = IDebtManager(0x8f9d2Cd33551CE06dD0564Ba147513F715c2F4a0);
    ICashbackDispatcher cashbackDispatcher = ICashbackDispatcher(0x7d372C3ca903CA2B6ecd8600D567eb6bAfC5e6c9);
    IPriceProvider priceProvider = IPriceProvider(0x8B4C8c403fc015C46061A8702799490FD616E3bf);
    address settlementDispatcher = 0x4Dca5093E0bB450D7f7961b5Df0A9d4c24B24786;
    address cashOwnerGnosisSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address owner;
    uint256 owner1Pk;
    uint256 owner2Pk;
    uint256 owner3Pk;
    uint256 notOwnerPk;
    address public owner1;
    address public owner2;
    address public owner3;
    address public notOwner;
    address public pauser;
    address public unpauser;

    uint8 threshold;

    address public module1;
    address public module2;
    CashModule public cashModule;
    CashLens public cashLens;

    uint256 dailyLimitInUsd = 10_000e6;
    uint256 monthlyLimitInUsd = 100_000e6;
    int256 timezoneOffset = -4 * 3600; // cayman timezone

    address public etherFiWallet = makeAddr("etherFiWallet");

    function setUp() public virtual {
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
        owner = makeAddr("owner");
        (owner1, owner1Pk) = makeAddrAndKey("owner1");
        (owner2, owner2Pk) = makeAddrAndKey("owner2");
        (owner3, owner3Pk) = makeAddrAndKey("owner3");
        (notOwner, notOwnerPk) = makeAddrAndKey("notOwner");

        vm.startPrank(owner);

        address dataProviderImpl = address(new EtherFiDataProvider());
        dataProvider = EtherFiDataProvider(address(new UUPSProxy(dataProviderImpl, "")));

        address roleRegistryImpl = address(new RoleRegistry(address(dataProvider)));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), owner);

        address cashModuleImpl = address(new CashModule(address(dataProvider)));
        cashModule = CashModule(address(
            new UUPSProxy(
                cashModuleImpl, 
                abi.encodeWithSelector(
                    CashModule.initialize.selector, 
                    address(roleRegistry), 
                    address(debtManager), 
                    settlementDispatcher, 
                    address(cashbackDispatcher)
                )
            )
        ));

        address cashLensImpl = address(new CashLens(address(cashModule), address(dataProvider)));
        cashLens = CashLens(address(new UUPSProxy(cashLensImpl, abi.encodeWithSelector(CashLens.initialize.selector, address(roleRegistry)))));

        roleRegistry.grantRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet);
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), owner);

        address hookImpl = address(new EtherFiHook(address(dataProvider)));
        hook = EtherFiHook(address(new UUPSProxy(hookImpl, abi.encodeWithSelector(EtherFiHook.initialize.selector, address(roleRegistry)))));

        address safeImpl = address(new EtherFiSafe(address(dataProvider)));
        address safeFactoryImpl = address(new EtherFiSafeFactory());
        safeFactory = EtherFiSafeFactory(address(new UUPSProxy(safeFactoryImpl, abi.encodeWithSelector(EtherFiSafeFactory.initialize.selector, address(roleRegistry), safeImpl))));

        module1 = address(new ModuleBase(address(dataProvider)));
        module2 = address(new ModuleBase(address(dataProvider)));

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        threshold = 2;

        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bytes[] memory moduleSetupData = new bytes[](2);

        dataProvider.initialize(address(roleRegistry), address(cashModule), address(cashLens), modules, address(hook), address(safeFactory), address(priceProvider));

        roleRegistry.grantRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), owner);
        safeFactory.deployEtherFiSafe(keccak256("safe"), owners, modules, moduleSetupData, threshold);
        safe = EtherFiSafe(safeFactory.getDeterministicAddress(keccak256("safe")));

        vm.stopPrank();
    }

    function _configureModules(address[] memory modules, bool[] memory shouldWhitelist, bytes[] memory setupData) internal {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), keccak256(abi.encode(setupData)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        _sendConfigureModules(modules, shouldWhitelist, setupData, abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));
    }

    function _sendConfigureModules(address[] memory modules, bool[] memory shouldWhitelist, bytes[] memory setupData, bytes memory sig1, bytes memory sig2) internal {
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = sig1;
        signatures[1] = sig2;

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.configureModules(modules, shouldWhitelist, setupData, signers, signatures);
    }

    function _configureAdmins(address[] memory accounts, bool[] memory shouldAdd) internal {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_ADMIN_TYPEHASH(), keccak256(abi.encodePacked(accounts)), keccak256(abi.encodePacked(shouldAdd)), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectEmit(true, true, true, true);
        emit EtherFiSafe.AdminsConfigured(accounts, shouldAdd);
        safe.configureAdmins(accounts, shouldAdd, signers, signatures);
    }

    function _configureOwners(address[] memory owners, bool[] memory shouldAdd) internal {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_OWNERS_TYPEHASH(), keccak256(abi.encodePacked(owners)), keccak256(abi.encodePacked(shouldAdd)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.configureOwners(owners, shouldAdd, signers, signatures);
    }

    function _setThreshold(uint8 newThreshold) internal {
        bytes32 structHash = keccak256(abi.encode(safe.SET_THRESHOLD_TYPEHASH(), newThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.setThreshold(newThreshold, signers, signatures);
    }
}
