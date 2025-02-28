// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IModule } from "../../src/interfaces/IModule.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors } from "../../src/safe/EtherFiSafe.sol";
import {EtherFiSafeFactory} from "../../src/safe/EtherFiSafeFactory.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";


contract SafeTestSetup is Test {
    using MessageHashUtils for bytes32;

    EtherFiSafeFactory public safeFactory;
    EtherFiSafe public safe;
    EtherFiDataProvider public dataProvider;
    RoleRegistry public roleRegistry;
    EtherFiHook public hook;

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
    address public cashModuleDummy;

    function setUp() public virtual {
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
        owner = makeAddr("owner");
        (owner1, owner1Pk) = makeAddrAndKey("owner1");
        (owner2, owner2Pk) = makeAddrAndKey("owner2");
        (owner3, owner3Pk) = makeAddrAndKey("owner3");
        (notOwner, notOwnerPk) = makeAddrAndKey("notOwner");

        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry());
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        address dataProviderImpl = address(new EtherFiDataProvider());
        dataProvider = EtherFiDataProvider(address(new UUPSProxy(dataProviderImpl, "")));

        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), owner);

        address hookImpl = address(new EtherFiHook(address(dataProvider)));
        hook = EtherFiHook(address(new UUPSProxy(hookImpl, abi.encodeWithSelector(EtherFiHook.initialize.selector, address(roleRegistry)))));

        address safeImpl = address(new EtherFiSafe(address(dataProvider)));
        address safeFactoryImpl = address(new EtherFiSafeFactory());
        safeFactory = EtherFiSafeFactory(address(new UUPSProxy(safeFactoryImpl, abi.encodeWithSelector(EtherFiSafeFactory.initialize.selector, address(roleRegistry), safeImpl))));

        module1 = address(new ModuleBase(address(dataProvider)));
        module2 = address(new ModuleBase(address(dataProvider)));
        cashModuleDummy = address(new ModuleBase(address(dataProvider)));

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        threshold = 2;

        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bytes[] memory moduleSetupData = new bytes[](2);


        dataProvider.initialize(address(roleRegistry), cashModuleDummy, modules, address(hook), address(safeFactory));

        roleRegistry.grantRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), owner);
        safeFactory.deployEtherFiSafe(keccak256("safe"), owners, modules, moduleSetupData, threshold);
        safe = EtherFiSafe(safeFactory.getDeterministicAddress(keccak256("safe")));
        
        vm.stopPrank();
    }

    function _configureModules(address[] memory modules, bool[] memory shouldWhitelist, bytes[] memory setupData, uint256 pk1, uint256 pk2) internal {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), keccak256(abi.encode(setupData)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk1, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, digestHash);

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

    function _configureModuleAdmin(address module, address[] memory accounts, bool[] memory shouldAdd, uint256 pk1, uint256 pk2) internal {
        bytes32 digestHash = keccak256(abi.encode(IModule(module).CONFIG_ADMIN(), block.chainid, module, IModule(module).getNonce(address(safe)), address(safe), accounts, shouldAdd)).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk1, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectEmit(true, true, true, true);
        emit ModuleBase.AdminsConfigured(address(safe), accounts, shouldAdd);
        IModule(module).configureAdmins(address(safe), accounts, shouldAdd, signers, signatures);
    }
}
