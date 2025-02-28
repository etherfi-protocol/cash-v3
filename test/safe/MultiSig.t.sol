// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "./SafeTestSetup.t.sol";
import { Test } from "forge-std/Test.sol";

contract MultiSigTest is SafeTestSetup {
    function test_setThreshold_updatesThreshold() public {
        uint8 newThreshold = 3;
        _setThreshold(newThreshold);
        assertEq(safe.getThreshold(), newThreshold);
    }

    function test_setThreshold_reverts_whenThresholdZero() public {
        uint8 newThreshold = 0;

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

        vm.expectRevert(EtherFiSafeErrors.InvalidThreshold.selector);
        safe.setThreshold(newThreshold, signers, signatures);
    }

    function test_setThreshold_reverts_whenThresholdAboveOwnerCount() public {
        uint8 newThreshold = 4; // Only 3 owners exist

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

        vm.expectRevert(EtherFiSafeErrors.InvalidThreshold.selector);
        safe.setThreshold(newThreshold, signers, signatures);
    }

    function test_configureOwners_addsNewOwner() public {
        address newOwner = makeAddr("newOwner");

        address[] memory owners = new address[](1);
        owners[0] = newOwner;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        _configureOwners(owners, shouldAdd);
        assertTrue(safe.isOwner(newOwner));
    }

    function test_configureOwners_removesExistingOwner() public {
        address[] memory owners = new address[](1);
        owners[0] = owner3;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = false;

        _configureOwners(owners, shouldAdd);
        assertFalse(safe.isOwner(owner3));
    }

    function testFuzz_configureOwners_correctlyUpdatesOwnerStatus(address[10] calldata ownerAddresses, bool[10] calldata shouldAddFlags) public {
        vm.assume(ownerAddresses[0] != address(0));
        vm.assume(ownerAddresses[1] != address(0));
        vm.assume(ownerAddresses[0] != ownerAddresses[1]);
        vm.assume(ownerAddresses[0] != owner1);
        vm.assume(ownerAddresses[1] != owner1);

        // Add assumption to exclude the sentinel value (Solady EnumerableSetLib sentinel value)
        vm.assume(uint160(ownerAddresses[0]) != uint160(0xfbb67fda52d4bfb8bf));
        vm.assume(uint160(ownerAddresses[1]) != uint160(0xfbb67fda52d4bfb8bf));

        address[] memory owners = new address[](2);
        owners[0] = ownerAddresses[0];
        owners[1] = ownerAddresses[1];

        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = shouldAddFlags[0];
        shouldAdd[1] = shouldAddFlags[1];

        _configureOwners(owners, shouldAdd);

        assertEq(safe.isOwner(owners[0]), shouldAdd[0]);
        assertEq(safe.isOwner(owners[1]), shouldAdd[1]);
    }

    function test_configureOwners_reverts_whenOwnersEmpty() public {
        address[] memory owners = new address[](0);
        bool[] memory shouldAdd = new bool[](0);

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

        vm.expectRevert(EtherFiSafeErrors.InvalidInput.selector);
        safe.configureOwners(owners, shouldAdd, signers, signatures);
    }

    function test_configureOwners_reverts_whenAllOwnersRemoved() public {
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        bool[] memory shouldAdd = new bool[](3);
        shouldAdd[0] = false;
        shouldAdd[1] = false;
        shouldAdd[2] = false;

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

        vm.expectRevert(EtherFiSafeErrors.AllOwnersRemoved.selector);
        safe.configureOwners(owners, shouldAdd, signers, signatures);
    }

    function test_configureOwners_reverts_whenOwnersLessThanThreshold() public {
        address[] memory owners = new address[](2);
        owners[0] = owner2;
        owners[1] = owner3;

        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = false;
        shouldAdd[1] = false;

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

        vm.expectRevert(EtherFiSafeErrors.OwnersLessThanThreshold.selector);
        safe.configureOwners(owners, shouldAdd, signers, signatures);
    }

    function test_checkSignatures_verifyValidSignatures() public view {
        bytes32 testHash = keccak256("test message");

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, testHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, testHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        assertTrue(safe.checkSignatures(testHash, signers, signatures));
    }

    function test_isOwner_returnsCorrectStatus() public view {
        assertTrue(safe.isOwner(owner1));
        assertTrue(safe.isOwner(owner2));
        assertTrue(safe.isOwner(owner3));
        assertFalse(safe.isOwner(notOwner));
    }

    function test_getOwners_returnsAllOwners() public view {
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 3);
        assertTrue(owners[0] == owner1);
        assertTrue(owners[1] == owner2);
        assertTrue(owners[2] == owner3);
    }

    function test_checkSignatures_reverts_whenEmptySigners() public {
        bytes32 testHash = keccak256("test message");

        address[] memory signers = new address[](0);
        bytes[] memory signatures = new bytes[](0);

        vm.expectRevert(EtherFiSafeErrors.EmptySigners.selector);
        safe.checkSignatures(testHash, signers, signatures);
    }

    function test_checkSignatures_reverts_whenArrayLengthMismatch() public {
        bytes32 testHash = keccak256("test message");

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, testHash);
        signatures[0] = abi.encodePacked(r, s, v);

        vm.expectRevert(EtherFiSafeErrors.ArrayLengthMismatch.selector);
        safe.checkSignatures(testHash, signers, signatures);
    }

    function test_checkSignatures_reverts_whenInsufficientSigners() public {
        bytes32 testHash = keccak256("test message");

        address[] memory signers = new address[](1); // Only 1 signer when threshold is 2
        signers[0] = owner1;

        bytes[] memory signatures = new bytes[](1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, testHash);
        signatures[0] = abi.encodePacked(r, s, v);

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        safe.checkSignatures(testHash, signers, signatures);
    }

    function test_checkSignatures_reverts_whenSignerIsZeroAddress() public {
        bytes32 testHash = keccak256("test message");

        address[] memory signers = new address[](2);
        signers[0] = address(0);
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, testHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, testHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        safe.checkSignatures(testHash, signers, signatures);
    }

    function test_checkSignatures_reverts_whenSignerNotOwner() public {
        bytes32 testHash = keccak256("test message");

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = notOwner;

        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, testHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(notOwnerPk, testHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 1));
        safe.checkSignatures(testHash, signers, signatures);
    }

    function test_checkSignatures_reverts_whenSignersDuplicated() public {
        bytes32 testHash = keccak256("test message");

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner1;

        bytes[] memory signatures = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, testHash);
        signatures[0] = abi.encodePacked(r, s, v);
        signatures[1] = signatures[0];

        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        safe.checkSignatures(testHash, signers, signatures);
    }

    function test_checkSignatures_returnsFalse_whenSignatureInvalid() public view {
        bytes32 testHash = keccak256("test message");
        bytes32 wrongHash = keccak256("wrong message");

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        // First signature signs wrong hash
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, wrongHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, testHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        assertFalse(safe.checkSignatures(testHash, signers, signatures));
    }

    function test_checkSignatures_succeedsWithExtraSignatures() public view {
        bytes32 testHash = keccak256("test message");

        // Provide 3 signatures when threshold is 2
        address[] memory signers = new address[](3);
        signers[0] = owner1;
        signers[1] = owner2;
        signers[2] = owner3;

        bytes[] memory signatures = new bytes[](3);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, testHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, testHash);
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(owner3Pk, testHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        signatures[2] = abi.encodePacked(r3, s3, v3);

        assertTrue(safe.checkSignatures(testHash, signers, signatures));
    }

    function test_checkSignatures_succeedsWithThresholdSignatures() public view {
        bytes32 testHash = keccak256("test message");

        // Exactly threshold (2) signatures
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, testHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, testHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        assertTrue(safe.checkSignatures(testHash, signers, signatures));
    }

    function test_checkSignatures_stopsAtThreshold() public view {
        bytes32 testHash = keccak256("test message");
        bytes32 wrongHash = keccak256("wrong message");

        // First two signatures are valid, third is invalid but should not affect result
        address[] memory signers = new address[](3);
        signers[0] = owner1;
        signers[1] = owner2;
        signers[2] = owner3;

        bytes[] memory signatures = new bytes[](3);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, testHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, testHash);
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(owner3Pk, wrongHash); // Invalid signature
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        signatures[2] = abi.encodePacked(r3, s3, v3);

        assertTrue(safe.checkSignatures(testHash, signers, signatures));
    }
}
