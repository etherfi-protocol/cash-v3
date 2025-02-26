// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "./SafeTestSetup.t.sol";

contract ModuleManagerTest is SafeTestSetup {
    function test_isModuleEnabled_identifiesCashModuleAsWhitelisted() public view {
        // Cash module should be treated as whitelisted even if not in local storage
        assertTrue(safe.isModuleEnabled(cashModule));
    }

    function test_isModuleEnabled_requiresModuleToBeWhitlisted() public {
        address nonWhitelistedModule = makeAddr("nonWhitelistedModule");

        address[] memory modules = new address[](1);
        modules[0] = nonWhitelistedModule;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        // A module must be whitelisted on dataProvider AND in local storage
        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        assertFalse(safe.isModuleEnabled(nonWhitelistedModule));
    }

    function test_configureModules_reverts_whenRemovingCashModule() public {
        // First add the cash module to the whitelist
        address[] memory modules = new address[](1);
        modules[0] = cashModule;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        // First add it to whitelist
        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);

        // Now try to remove it
        shouldWhitelist[0] = false;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.CannotRemoveCashModule.selector, 0));
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenAddingUnsupportedModule() public {
        address nonWhitelistedModule = makeAddr("nonWhitelistedModule");

        address[] memory modules = new address[](1);
        modules[0] = nonWhitelistedModule;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.UnsupportedModule.selector, 0));
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_requiresDataProviderWhitelisting() public {
        address newModule = makeAddr("newModule");

        // First whitelist the module in data provider
        address[] memory dpModules = new address[](1);
        dpModules[0] = newModule;
        bool[] memory dpShouldWhitelist = new bool[](1);
        dpShouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(dpModules, dpShouldWhitelist);

        // Now add it to the safe
        address[] memory modules = new address[](1);
        modules[0] = newModule;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);
        assertTrue(safe.isModuleEnabled(newModule));
    }

    function test_configureModules_checksForDuplicates() public {
        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module1; // Duplicate

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_addsModulesToWhitelist() public {
        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);
        assertTrue(safe.isModuleEnabled(module1));
        assertTrue(safe.isModuleEnabled(module2));
    }

    function testFuzz_configureModules_correctlyUpdatesModuleStatus(address[10] calldata moduleAddresses, bool[10] calldata shouldWhitelistFlags) public {
        vm.assume(moduleAddresses[0] != address(0));
        vm.assume(moduleAddresses[1] != address(0));
        vm.assume(moduleAddresses[0] != moduleAddresses[1]);

        // Add assumption to exclude the sentinel value (Solady EnumerableSetLib sentinel value)
        vm.assume(uint160(moduleAddresses[0]) != uint160(0xfbb67fda52d4bfb8bf));
        vm.assume(uint160(moduleAddresses[1]) != uint160(0xfbb67fda52d4bfb8bf));

        address[] memory modules = new address[](2);
        modules[0] = moduleAddresses[0];
        modules[1] = moduleAddresses[1];

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = shouldWhitelistFlags[0];
        shouldWhitelist[1] = shouldWhitelistFlags[1];

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);

        if (modules[0] == cashModule) {
            assertTrue(safe.isModuleEnabled(modules[0]));
        } else {
            if (shouldWhitelist[0]) assertTrue(safe.isModuleEnabled(modules[0]));
            else assertFalse(safe.isModuleEnabled(modules[0]));
        }

        if (modules[1] == cashModule) {
            assertTrue(safe.isModuleEnabled(modules[1]));
        } else {
            if (shouldWhitelist[1]) assertTrue(safe.isModuleEnabled(modules[1]));
            else assertFalse(safe.isModuleEnabled(modules[1]));
        }
    }

    function test_configureModules_reverts_whenModulesEmpty() public {
        address[] memory modules = new address[](0);
        bool[] memory shouldWhitelist = new bool[](0);

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(EtherFiSafeErrors.InvalidInput.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenArrayLengthMismatch() public {
        address[] memory modules = new address[](2);
        bool[] memory shouldWhitelist = new bool[](1);

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(EtherFiSafeErrors.ArrayLengthMismatch.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenModuleAddressZero() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidModule.selector, 0));
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenSignaturesInvalid() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = signatures[0];

        vm.expectRevert(EtherFiSafeErrors.InvalidSignatures.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenSignerNotOwner() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = notOwner;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(notOwnerPk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 1));
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenSignersDuplicated() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = signatures[0];

        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenSignersBelowThreshold() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory signers = new address[](1); // Only 1 signer when threshold is 2
        signers[0] = owner1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_getModules_returnsCorrectModules() public {
        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);

        address[] memory registeredModules = safe.getModules();
        assertEq(registeredModules.length, 2);
        assertTrue(registeredModules[0] == module1);
        assertTrue(registeredModules[1] == module2);
    }
}
