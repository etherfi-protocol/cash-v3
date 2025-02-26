// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { ModuleBase } from "../../../src/modules/ModuleBase.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, EtherFiDataProvider } from "../../safe/SafeTestSetup.t.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ModuleBaseTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    ModuleBase public moduleBase;
    uint256 public moduleAdminPk;
    address public moduleAdmin;
    uint256 public nonAdminPk;
    address public nonAdmin;

    function setUp() public override {
        vm.createSelectFork("https://rpc.scroll.io");

        super.setUp();

        (moduleAdmin, moduleAdminPk) = makeAddrAndKey("moduleAdmin");
        (nonAdmin, nonAdminPk) = makeAddrAndKey("nonAdmin");

        moduleBase = new ModuleBase(address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(moduleBase);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);
        
        // Add module admin
        address[] memory accounts = new address[](1);
        accounts[0] = moduleAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        _configureModuleAdmin(address(moduleBase), accounts, shouldAdd, owner1Pk, owner2Pk);
    }

    // Module configuration tests
    function test_isModuleEnabled_returnsTrue_whenModuleIsWhitelisted() public view {
        assertTrue(safe.isModuleEnabled(address(moduleBase)));
    }

    function test_hasAdminRole_returnsTrue_whenAccountIsAdmin() public view {
        assertTrue(moduleBase.hasAdminRole(address(safe), moduleAdmin));
    }

    function test_hasAdminRole_returnsFalse_whenAccountIsNotAdmin() public view {
        assertFalse(moduleBase.hasAdminRole(address(safe), nonAdmin));
    }

    function test_hasAdminRole_reverts_whenAddressIsNotADeployedSafe() public {
        vm.expectRevert(EtherFiDataProvider.OnlyEtherFiSafe.selector);
        moduleBase.hasAdminRole(makeAddr("safe"), moduleAdmin);
    }

    // Admin configuration tests
    function test_configureModuleAdmin_addsAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = nonAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        _configureModuleAdmin(address(moduleBase), accounts, shouldAdd, owner1Pk, owner2Pk);
        
        assertTrue(moduleBase.hasAdminRole(address(safe), nonAdmin));
    }

    function test_configureModuleAdmin_removesAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = moduleAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = false;

        _configureModuleAdmin(address(moduleBase), accounts, shouldAdd, owner1Pk, owner2Pk);
        
        assertFalse(moduleBase.hasAdminRole(address(safe), moduleAdmin));
    }

    function test_configureModuleAdmin_reverts_whenAddressIsNotADeployedSafe() public {
        address[] memory accounts = new address[](1);
        accounts[0] = moduleAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = false;

        bytes[] memory signatures = new bytes[](2);
        address[] memory signers = new address[](2);

        vm.expectRevert(EtherFiDataProvider.OnlyEtherFiSafe.selector);
        moduleBase.configureAdmins(makeAddr("safe"), accounts, shouldAdd, signers, signatures);
    }

    function test_configureModuleAdmin_reverts_whenSignatureIsInvalid() public {
        address[] memory accounts = new address[](1);
        accounts[0] = nonAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        bytes32 configModuleAdminHash = keccak256(abi.encode(
            moduleBase.CONFIG_ADMIN(),
            block.chainid,
            address(moduleBase),
            moduleBase.getNonce(address(safe)),
            address(safe),
            accounts,
            shouldAdd
        ));
        
        bytes32 digestHash = configModuleAdminHash.toEthSignedMessageHash();
        
        // Sign with incorrect private key
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(nonAdminPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(moduleAdminPk, digestHash);
        
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        address[] memory signers = new address[](2);
        signers[0] = nonAdmin;
        signers[1] = moduleAdmin;
        
        vm.expectRevert(); // Exact error may vary based on implementation
        moduleBase.configureAdmins(address(safe), accounts, shouldAdd, signers, signatures);
    }
}