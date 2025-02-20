// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ArrayDeDupLib, EtherFiSafe, ModuleManager } from "../../src/safe/EtherFiSafe.sol";

contract ModuleManagerTest is Test {
    EtherFiSafe public safe;

    uint256 owner1Pk;
    uint256 owner2Pk;
    uint256 owner3Pk;
    uint256 notOwnerPk;
    address public owner1;
    address public owner2;
    address public owner3;
    address public notOwner;

    uint8 threshold;

    address public module1 = makeAddr("module1");
    address public module2 = makeAddr("module2");

    function setUp() public {
        (owner1, owner1Pk) = makeAddrAndKey("owner1");
        (owner2, owner2Pk) = makeAddrAndKey("owner2");
        (owner3, owner3Pk) = makeAddrAndKey("owner3");
        (notOwner, notOwnerPk) = makeAddrAndKey("notOwner");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        threshold = 2;

        safe = new EtherFiSafe();
        safe.initialize(owners, threshold);
    }

    function test_configureModules_addsModulesToWhitelist() public {
        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);
        assertTrue(safe.isModule(module1));
        assertTrue(safe.isModule(module2));
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

        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);

        if (shouldWhitelist[0]) assertTrue(safe.isModule(modules[0]));
        else assertFalse(safe.isModule(modules[0]));

        if (shouldWhitelist[1]) assertTrue(safe.isModule(modules[1]));
        else assertFalse(safe.isModule(modules[1]));
    }

    function test_configureModules_reverts_whenModulesEmpty() public {
        address[] memory modules = new address[](0);
        bool[] memory shouldWhitelist = new bool[](0);

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(ModuleManager.InvalidInput.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenArrayLengthMismatch() public {
        address[] memory modules = new address[](2);
        bool[] memory shouldWhitelist = new bool[](1);

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(ModuleManager.ArrayLengthMismatch.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenModuleAddressZero() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectRevert(abi.encodeWithSelector(ModuleManager.InvalidModule.selector, 0));
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenSignaturesInvalid() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = signatures[0];

        vm.expectRevert(EtherFiSafe.InvalidSignatures.selector);
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenSignerNotOwner() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = notOwner;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(notOwnerPk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafe.InvalidSigner.selector, 1));
        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }

    function test_configureModules_reverts_whenSignersDuplicated() public {
        address[] memory modules = new address[](1);
        modules[0] = module1;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

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

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory signers = new address[](1); // Only 1 signer when threshold is 2
        signers[0] = owner1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);

        vm.expectRevert(EtherFiSafe.InsufficientSigners.selector);
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

    function _configureModules(address[] memory modules, bool[] memory shouldWhitelist, uint256 pk1, uint256 pk2) public {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), safe.nonces(address(this))));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk1, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.configureModules(modules, shouldWhitelist, signers, signatures);
    }
}
