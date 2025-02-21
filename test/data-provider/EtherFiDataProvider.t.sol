// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract EtherFiDataProviderTest is Test {
    EtherFiDataProvider public provider;
    RoleRegistry public roleRegistry;

    address public owner = makeAddr("owner");
    address public admin = address(0x1);
    address public nonAdmin = address(0x2);

    address public module1 = address(0x100);
    address public module2 = address(0x200);
    address public module3 = address(0x300);
    address public hookAddress = address(0x400);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    event ModulesConfigured(address[] modules, bool[] shouldWhitelist);
    event HookAddressUpdated(address oldHookAddress, address newHookAddress);

    function setUp() public {
        // Deploy role registry and grant admin role
        address roleRegistryImpl = address(new RoleRegistry());
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        vm.prank(owner);
        roleRegistry.grantRole(ADMIN_ROLE, admin);

        // Deploy provider
        provider = new EtherFiDataProvider();

        // Initialize with initial modules
        address[] memory initialModules = new address[](2);
        initialModules[0] = module1;
        initialModules[1] = module2;

        bool[] memory initialWhitelist = new bool[](2);
        initialWhitelist[0] = true;
        initialWhitelist[1] = true;

        vm.prank(admin);
        provider.initialize(address(roleRegistry), initialModules, initialWhitelist, hookAddress);
    }

    // Initialize Tests

    function test_initialize_setsInitialModules() public view {
        assertEq(provider.isWhitelistedModule(module1), true);
        assertEq(provider.isWhitelistedModule(module2), true);
        assertEq(provider.isWhitelistedModule(module3), false);
    }

    function test_initialize_setsHookAddress() public view {
        assertEq(provider.getHookAddress(), hookAddress);
    }

    function test_initialize_reverts_whenCalledTwice() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        provider.initialize(address(roleRegistry), modules, whitelist, hookAddress);
    }

    function test_initialize_reverts_whenModuleArraysLengthMismatch() public {
        EtherFiDataProvider newProvider = new EtherFiDataProvider();

        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.ArrayLengthMismatch.selector);
        newProvider.initialize(address(roleRegistry), modules, whitelist, hookAddress);
    }

    function test_initialize_reverts_whenEmptyModuleArray() public {
        EtherFiDataProvider newProvider = new EtherFiDataProvider();

        address[] memory modules = new address[](0);
        bool[] memory whitelist = new bool[](0);

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        newProvider.initialize(address(roleRegistry), modules, whitelist, hookAddress);
    }

    function test_initialize_reverts_whenZeroAddressModule() public {
        EtherFiDataProvider newProvider = new EtherFiDataProvider();

        address[] memory modules = new address[](1);
        modules[0] = address(0);

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EtherFiDataProvider.InvalidModule.selector, 0));
        newProvider.initialize(address(roleRegistry), modules, whitelist, hookAddress);
    }

    function test_initialize_reverts_whenZeroAddressHook() public {
        EtherFiDataProvider newProvider = new EtherFiDataProvider();

        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        newProvider.initialize(address(roleRegistry), modules, whitelist, address(0));
    }

    // Configure Modules Tests

    function test_configureModules_addsNewModule() public {
        address[] memory modules = new address[](1);
        modules[0] = module3;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ModulesConfigured(modules, whitelist);
        provider.configureModules(modules, whitelist);

        assertEq(provider.isWhitelistedModule(module3), true);
    }

    function test_configureModules_removesExistingModule() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = false;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ModulesConfigured(modules, whitelist);
        provider.configureModules(modules, whitelist);

        assertEq(provider.isWhitelistedModule(module1), false);
    }

    function test_configureModules_reverts_whenCalledByNonAdmin() public {
        address[] memory modules = new address[](1);
        modules[0] = module3;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(nonAdmin);
        vm.expectRevert(EtherFiDataProvider.OnlyAdmin.selector);
        provider.configureModules(modules, whitelist);
    }

    function test_configureModules_reverts_whenArrayLengthMismatch() public {
        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.ArrayLengthMismatch.selector);
        provider.configureModules(modules, whitelist);
    }

    function test_configureModules_reverts_whenEmptyArray() public {
        address[] memory modules = new address[](0);
        bool[] memory whitelist = new bool[](0);

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        provider.configureModules(modules, whitelist);
    }

    function test_configureModules_reverts_whenZeroAddressModule() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0);

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EtherFiDataProvider.InvalidModule.selector, 0));
        provider.configureModules(modules, whitelist);
    }

    // Set Hook Address Tests

    function test_setHookAddress_updatesAddress() public {
        address newHook = address(0x500);

        vm.prank(admin);
        provider.setHookAddress(newHook);

        assertEq(provider.getHookAddress(), newHook);
    }

    function test_setHookAddress_emitsEvent() public {
        address newHook = address(0x500);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit HookAddressUpdated(hookAddress, newHook);
        provider.setHookAddress(newHook);
    }

    function test_setHookAddress_reverts_whenCalledByNonAdmin() public {
        address newHook = address(0x500);

        vm.prank(nonAdmin);
        vm.expectRevert(EtherFiDataProvider.OnlyAdmin.selector);
        provider.setHookAddress(newHook);
    }

    function test_setHookAddress_reverts_whenZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        provider.setHookAddress(address(0));
    }

    // View Function Tests

    function test_isWhitelistedModule_returnsCorrectStatus() public view {
        assertEq(provider.isWhitelistedModule(module1), true);
        assertEq(provider.isWhitelistedModule(module2), true);
        assertEq(provider.isWhitelistedModule(module3), false);
        assertEq(provider.isWhitelistedModule(address(0)), false);
    }

    function test_getWhitelistedModules_returnsAllWhitelistedModules() public view {
        address[] memory whitelistedModules = provider.getWhitelistedModules();

        assertEq(whitelistedModules.length, 2);
        assertEq(whitelistedModules[0], module1);
        assertEq(whitelistedModules[1], module2);
    }

    function test_getHookAddress_returnsCurrentHookAddress() public view {
        assertEq(provider.getHookAddress(), hookAddress);
    }
}
