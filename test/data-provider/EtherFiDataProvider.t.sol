// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ArrayDeDupLib } from "../../src/libraries/ArrayDeDupLib.sol";
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
    address public cashModule = address(0x500);
    address public cashLens = address(0x600);
    address public safeFactory = address(0x700);
    address public priceProvider = address(0x800);
    address public etherFiRecoverySigner = address(0x900);
    address public thirdPartyRecoverySigner = address(0x1100);
    address public newEtherFiRecoverySigner = address(0x1200);
    address public newThirdPartyRecoverySigner = address(0x1300);

    uint256 public defaultRecoveryPeriod = 3 days;
    uint256 public newRecoveryPeriod = 7 days;


    event ModulesConfigured(address[] modules, bool[] shouldWhitelist);
    event HookAddressUpdated(address oldHookAddress, address newHookAddress);

    function setUp() public {
        vm.startPrank(owner);
        // Initialize with initial modules
        address[] memory initialModules = new address[](2);
        initialModules[0] = module1;
        initialModules[1] = module2;
        address[] memory defaultModules = new address[](1);
        defaultModules[0] = module1;
        
        // Deploy provider
        address dataProviderImpl = address(new EtherFiDataProvider());
        provider = EtherFiDataProvider(address(new UUPSProxy(dataProviderImpl, "")));

        // Deploy role registry and grant admin role
        address roleRegistryImpl = address(new RoleRegistry(address(provider)));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        provider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(cashModule), cashLens, initialModules, defaultModules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));

        roleRegistry.grantRole(provider.DATA_PROVIDER_ADMIN_ROLE(), admin);
        vm.stopPrank();
    }

    // Initialize Tests

    function test_initialize_setsInitialValues() public view {
        assertEq(provider.isWhitelistedModule(module1), true);
        assertEq(provider.isWhitelistedModule(module2), true);
        assertEq(provider.isWhitelistedModule(module3), false);

        assertEq(provider.getHookAddress(), hookAddress);
        assertEq(provider.getCashModule(), cashModule);
    }

    function test_initialize_reverts_whenCalledTwice() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;
        address[] memory defaultModules = new address[](1);
        defaultModules[0] = module1;

        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        provider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(0), cashModule, modules, defaultModules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }

    function test_initialize_withoutHook() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory initialModules = new address[](2);
        initialModules[0] = module1;
        initialModules[1] = module2;
        address[] memory defaultModules = new address[](1);
        defaultModules[0] = module1;

        vm.prank(admin);
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), cashModule, cashLens, initialModules, defaultModules, address(0), safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));

        // Hook should be zero address since we didn't set it
        assertEq(newProvider.getHookAddress(), address(0));

        // Other settings should still be set
        assertEq(newProvider.isWhitelistedModule(module1), true);
        assertEq(newProvider.getCashModule(), cashModule);
    }

    function test_initialize_withoutCashModule() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory initialModules = new address[](2);
        initialModules[0] = module1;
        initialModules[1] = module2;
        address[] memory defaultModules = new address[](1);
        defaultModules[0] = module1;

        vm.prank(admin);
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(0), cashLens, initialModules, defaultModules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));

        // Cash module should be zero address since we didn't set it
        assertEq(newProvider.getCashModule(), address(0));

        // Other settings should still be set
        assertEq(newProvider.isWhitelistedModule(module1), true);
        assertEq(newProvider.getHookAddress(), hookAddress);
    }

    function test_initialize_reverts_whenEmptyModuleArray() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](0);

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(0), cashLens, modules, modules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }
    function test_initialize_reverts_whenEmptyDefaultModuleArray() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](1);
        modules[0] = module1;
        address[] memory defaultModules = new address[](0);

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(0), cashLens, modules, defaultModules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }

    function test_initialize_reverts_whenZeroAddressModule() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](1);
        modules[0] = address(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EtherFiDataProvider.InvalidModule.selector, 0));
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(0), cashLens, modules, modules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }

    function test_initialize_reverts_whenZeroAddressDefaultModule() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](1);
        modules[0] = address(1);
        address[] memory defaultModules = new address[](1);
        modules[0] = address(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EtherFiDataProvider.InvalidModule.selector, 0));
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(0), cashLens, modules, defaultModules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }

    function test_initialize_emits_hookAddressUpdatedEvent() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](1);
        modules[0] = module1;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.HookAddressUpdated(address(0), hookAddress);
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), cashModule, cashLens, modules, modules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }

    function test_initialize_emits_modulesSetupEvent() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](1);
        modules[0] = module1;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.ModulesSetup(modules);
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), cashModule, cashLens, modules, modules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }

    function test_initialize_emits_defaultModulesSetupEvent() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](1);
        modules[0] = module1;

        address[] memory defaultModules = new address[](2);
        defaultModules[0] = module1;
        defaultModules[1] = module2;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.DefaultModulesSetup(defaultModules);
        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), cashModule, cashLens, modules, defaultModules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
    }

    function test_initialize_emits_cashModuleConfiguredEvent() public {
        address newImpl = address(new EtherFiDataProvider());
        EtherFiDataProvider newProvider = EtherFiDataProvider(address(new UUPSProxy(newImpl, "")));

        address[] memory modules = new address[](1);
        modules[0] = module1;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.CashModuleConfigured(address(0), cashModule);

        newProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), cashModule, cashLens, modules, modules, hookAddress, safeFactory, priceProvider, etherFiRecoverySigner, thirdPartyRecoverySigner));
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

    function test_configureModules_removesExistingModuleFromDefaultModule() public {
        assertEq(provider.isWhitelistedModule(module1), true);
        assertEq(provider.isDefaultModule(module1), true);

        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = false;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ModulesConfigured(modules, whitelist);
        provider.configureModules(modules, whitelist);

        assertEq(provider.isWhitelistedModule(module1), false);
        assertEq(provider.isDefaultModule(module1), false);
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

    function test_configureModules_checksForDuplicates() public {
        // Create array with duplicate modules
        address[] memory modules = new address[](2);
        modules[0] = module3;
        modules[1] = module3;

        bool[] memory whitelist = new bool[](2);
        whitelist[0] = true;
        whitelist[1] = true;

        // Expect revert due to duplicates
        vm.prank(admin);
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        provider.configureModules(modules, whitelist);
    }

    // Configure Default Modules Tests
    function test_configureDefaultModules_addsNewModule() public {
        address[] memory modules = new address[](1);
        modules[0] = module3;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.DefaultModulesConfigured(modules, whitelist);
        provider.configureDefaultModules(modules, whitelist);

        assertEq(provider.isDefaultModule(module3), true);
        assertEq(provider.isWhitelistedModule(module3), true);
    }

    function test_configureDefaultModules_removesExistingModuleFromDefaultModules() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = false;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.DefaultModulesConfigured(modules, whitelist);
        provider.configureDefaultModules(modules, whitelist);

        assertEq(provider.isDefaultModule(module1), false);
        assertEq(provider.isWhitelistedModule(module1), true);
    }

    function test_configureDefaultModules_reverts_whenCalledByNonAdmin() public {
        address[] memory modules = new address[](1);
        modules[0] = module3;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(nonAdmin);
        vm.expectRevert(EtherFiDataProvider.OnlyAdmin.selector);
        provider.configureDefaultModules(modules, whitelist);
    }

    function test_configureDefaultModules_reverts_whenArrayLengthMismatch() public {
        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.ArrayLengthMismatch.selector);
        provider.configureDefaultModules(modules, whitelist);
    }

    function test_configureDefaultModules_reverts_whenEmptyArray() public {
        address[] memory modules = new address[](0);
        bool[] memory whitelist = new bool[](0);

        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        provider.configureDefaultModules(modules, whitelist);
    }

    function test_configureDefaultModules_reverts_whenZeroAddressModule() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0);

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EtherFiDataProvider.InvalidModule.selector, 0));
        provider.configureDefaultModules(modules, whitelist);
    }

    function test_configureDefaultModules_checksForDuplicates() public {
        // Create array with duplicate modules
        address[] memory modules = new address[](2);
        modules[0] = module3;
        modules[1] = module3;

        bool[] memory whitelist = new bool[](2);
        whitelist[0] = true;
        whitelist[1] = true;

        // Expect revert due to duplicates
        vm.prank(admin);
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        provider.configureDefaultModules(modules, whitelist);
    }

    // Cash Module Tests

    function test_setCashModule_updatesAddress() public {
        address newCashModule = address(0x600);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.CashModuleConfigured(cashModule, newCashModule);
        provider.setCashModule(newCashModule);

        assertEq(provider.getCashModule(), newCashModule);
    }

    function test_setCashModule_reverts_whenCalledByNonAdmin() public {
        address newCashModule = address(0x600);

        vm.prank(nonAdmin);
        vm.expectRevert(EtherFiDataProvider.OnlyAdmin.selector);
        provider.setCashModule(newCashModule);
    }

    function test_setCashModule_reverts_whenZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidCashModule.selector);
        provider.setCashModule(address(0));
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
        emit EtherFiDataProvider.HookAddressUpdated(hookAddress, newHook);
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

    function test_getCashModule_returnsCurrentCashModule() public view {
        assertEq(provider.getCashModule(), cashModule);
    }

        function test_initialize_setsRecoverySigners() public view {
        assertEq(provider.getEtherFiRecoverySigner(), etherFiRecoverySigner);
        assertEq(provider.getThirdPartyRecoverySigner(), thirdPartyRecoverySigner);
    }

    function test_initialize_setsDefaultRecoveryPeriod() public view {
        assertEq(provider.getRecoveryDelayPeriod(), defaultRecoveryPeriod);
    }

    function test_setEtherFiRecoverySigner_updatesAddress() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.EtherFiRecoverySignerConfigured(etherFiRecoverySigner, newEtherFiRecoverySigner);
        provider.setEtherFiRecoverySigner(newEtherFiRecoverySigner);

        assertEq(provider.getEtherFiRecoverySigner(), newEtherFiRecoverySigner);
    }

    function test_setEtherFiRecoverySigner_reverts_whenCalledByNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(EtherFiDataProvider.OnlyAdmin.selector);
        provider.setEtherFiRecoverySigner(newEtherFiRecoverySigner);
    }

    function test_setEtherFiRecoverySigner_reverts_whenZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        provider.setEtherFiRecoverySigner(address(0));
    }

    // Third Party Recovery Signer Tests

    function test_setThirdPartyRecoverySigner_updatesAddress() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.ThirdPartyRecoverySignerConfigured(thirdPartyRecoverySigner, newThirdPartyRecoverySigner);
        provider.setThirdPartyRecoverySigner(newThirdPartyRecoverySigner);

        assertEq(provider.getThirdPartyRecoverySigner(), newThirdPartyRecoverySigner);
    }

    function test_setThirdPartyRecoverySigner_reverts_whenCalledByNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(EtherFiDataProvider.OnlyAdmin.selector);
        provider.setThirdPartyRecoverySigner(newThirdPartyRecoverySigner);
    }

    function test_setThirdPartyRecoverySigner_reverts_whenZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        provider.setThirdPartyRecoverySigner(address(0));
    }

    // Recovery Delay Period Tests

    function test_setRecoveryDelayPeriod_updatesValue() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit EtherFiDataProvider.RecoveryDelayPeriodUpdated(defaultRecoveryPeriod, newRecoveryPeriod);
        provider.setRecoveryDelayPeriod(newRecoveryPeriod);

        assertEq(provider.getRecoveryDelayPeriod(), newRecoveryPeriod);
    }

    function test_setRecoveryDelayPeriod_reverts_whenZeroValue() public {
        vm.prank(admin);
        vm.expectRevert(EtherFiDataProvider.InvalidInput.selector);
        provider.setRecoveryDelayPeriod(0);
    }

    function test_setRecoveryDelayPeriod_reverts_whenCalledByNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(EtherFiDataProvider.OnlyAdmin.selector);
        provider.setRecoveryDelayPeriod(newRecoveryPeriod);
    }

    // Testing all getter functions

    function test_getAllRecoveryParameters() public view {
        assertEq(provider.getEtherFiRecoverySigner(), etherFiRecoverySigner);
        assertEq(provider.getThirdPartyRecoverySigner(), thirdPartyRecoverySigner);
        assertEq(provider.getRecoveryDelayPeriod(), defaultRecoveryPeriod);
    }

    // Integration Test - Update all recovery parameters at once

    function test_updateAllRecoveryParameters() public {
        // Update EtherFi recovery signer
        vm.startPrank(admin);
        provider.setEtherFiRecoverySigner(newEtherFiRecoverySigner);
        
        // Update third party recovery signer
        provider.setThirdPartyRecoverySigner(newThirdPartyRecoverySigner);
        
        // Update recovery delay period
        provider.setRecoveryDelayPeriod(newRecoveryPeriod);
        vm.stopPrank();

        // Verify all parameters were updated correctly
        assertEq(provider.getEtherFiRecoverySigner(), newEtherFiRecoverySigner);
        assertEq(provider.getThirdPartyRecoverySigner(), newThirdPartyRecoverySigner);
        assertEq(provider.getRecoveryDelayPeriod(), newRecoveryPeriod);
    }

}
