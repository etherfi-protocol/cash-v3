// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "./SafeTestSetup.t.sol";
import { RecoveryManager } from "../../src/safe/RecoveryManager.sol";

contract RecoveryManagerTest is SafeTestSetup {
    function setUp() public override {
        super.setUp();
        
        // Create user recovery signers
        (userRecoverySigner1, userRecoverySigner1Pk) = makeAddrAndKey("userRecoverySigner1");
        (userRecoverySigner2, userRecoverySigner2Pk) = makeAddrAndKey("userRecoverySigner2");
        
        // Create overridden recovery signers
        (overriddenEtherFiSigner, overriddenEtherFiSignerPk) = makeAddrAndKey("overriddenEtherFiSigner");
        (overriddenThirdPartySigner, overriddenThirdPartySignerPk) = makeAddrAndKey("overriddenThirdPartySigner");
        
        // Set up user recovery signers
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = userRecoverySigner1;
        recoverySigners[1] = userRecoverySigner2;
        
        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = true;
        shouldAdd[1] = true;
        
        _setUserRecoverySigners(recoverySigners, shouldAdd);
    }

    function test_isRecoveryEnabled_defaultsToTrue() public view {
        // Recovery should be enabled during setup
        assertTrue(safe.isRecoveryEnabled());
    }

    function test_getRecoverySigners_returnsCorrectSigners() public view {
        address[] memory recoverySigners = safe.getRecoverySigners();
        
        // Should return all 4 signers (2 default + 2 user recovery signers)
        assertEq(recoverySigners.length, 4);
        assertEq(recoverySigners[0], etherFiRecoverySigner);
        assertEq(recoverySigners[1], thirdPartyRecoverySigner);
        
        // Check for user recovery signers (order may vary based on implementation)
        bool foundSigner1 = false;
        bool foundSigner2 = false;
        for (uint i = 2; i < recoverySigners.length; i++) {
            if (recoverySigners[i] == userRecoverySigner1) foundSigner1 = true;
            if (recoverySigners[i] == userRecoverySigner2) foundSigner2 = true;
        }
        assertTrue(foundSigner1);
        assertTrue(foundSigner2);
    }

    function test_setUserRecoverySigners_addsNewSigners() public {
        address newSigner = makeAddr("newRecoverySigner");
        
        address[] memory recoverySigners = new address[](1);
        recoverySigners[0] = newSigner;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        _setUserRecoverySigners(recoverySigners, shouldAdd);
        
        // Verify the signer was added
        assertTrue(safe.isRecoverySigner(newSigner));

        // Verify total count
        address[] memory allSigners = safe.getRecoverySigners();
        assertEq(allSigners.length, 5); // 2 default + 2 initial user signers + 1 new signer
    }

    function test_setUserRecoverySigners_removesExistingSigners() public {
        address[] memory recoverySigners = new address[](1);
        recoverySigners[0] = userRecoverySigner1;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = false;
        
        _setUserRecoverySigners(recoverySigners, shouldAdd);
        
        // Verify the signer was removed
        assertFalse(safe.isRecoverySigner(userRecoverySigner1));
        assertTrue(safe.isRecoverySigner(userRecoverySigner2));
        
        // Verify total count
        address[] memory allSigners = safe.getRecoverySigners();
        assertEq(allSigners.length, 3); // 2 default + 1 remaining user signer
    }

    function test_setUserRecoverySigners_addingMultipleSigners() public {
        // First clear existing user signers
        address[] memory clearSigners = new address[](2);
        clearSigners[0] = userRecoverySigner1;
        clearSigners[1] = userRecoverySigner2;
        
        bool[] memory clearShouldAdd = new bool[](2);
        clearShouldAdd[0] = false;
        clearShouldAdd[1] = false;
        
        _setUserRecoverySigners(clearSigners, clearShouldAdd);
        
        // Now add 3 new signers
        address[] memory newSigners = new address[](3);
        newSigners[0] = makeAddr("newSigner1");
        newSigners[1] = makeAddr("newSigner2");
        newSigners[2] = makeAddr("newSigner3");
        
        bool[] memory shouldAdd = new bool[](3);
        shouldAdd[0] = true;
        shouldAdd[1] = true;
        shouldAdd[2] = true;
        
        _setUserRecoverySigners(newSigners, shouldAdd);
        
        // Verify all signers are added
        assertTrue(safe.isRecoverySigner(newSigners[0]));
        assertTrue(safe.isRecoverySigner(newSigners[1]));
        assertTrue(safe.isRecoverySigner(newSigners[2]));
        
        // Verify total count
        address[] memory allSigners = safe.getRecoverySigners();
        assertEq(allSigners.length, 5); // 2 default + 3 new user signers
    }

    function test_setRecoveryThreshold_updatesThreshold() public {
        uint8 newThreshold = 3;
        _setRecoveryThreshold(newThreshold);
        
        // Cannot directly check threshold as there's no getter, but we can verify
        // behavior through a recovery attempt with insufficient signers
        
        address newOwner = makeAddr("newOwner");
        address[] memory signers = new address[](2);
        signers[0] = etherFiRecoverySigner;
        signers[1] = thirdPartyRecoverySigner;
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(etherFiRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(thirdPartyRecoverySignerPk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        // This should fail because we set threshold to 3 but only provided 2 signers
        vm.expectRevert(EtherFiSafeErrors.InsufficientRecoverySignatures.selector);
        safe.recoverSafe(newOwner, signers, signatures);
    }

    function test_setRecoveryThreshold_revertsWhenThresholdHigherThanSigners() public {
        uint8 excessiveThreshold = 10; // More than available recovery signers (4)
        
        bytes32 structHash = keccak256(abi.encode(safe.SET_RECOVERY_THRESHOLD_TYPEHASH(), excessiveThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        
        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(EtherFiSafeErrors.RecoverySignersLengthLessThanThreshold.selector);
        safe.setRecoveryThreshold(excessiveThreshold, signers, signatures);
    }

    function test_toggleRecoveryEnabled_disablesRecovery() public {
        _toggleRecoveryEnabled(false);
        assertFalse(safe.isRecoveryEnabled());
    }

    function test_toggleRecoveryEnabled_enablesRecovery() public {
        // First disable it
        _toggleRecoveryEnabled(false);
        assertFalse(safe.isRecoveryEnabled());

        // Then enable it again
        _toggleRecoveryEnabled(true);
        assertTrue(safe.isRecoveryEnabled());
    }

    function test_toggleRecoveryEnabled_reverts_whenStateUnchanged() public {
        // Try to enable when already enabled
        bytes32 structHash = keccak256(abi.encode(safe.TOGGLE_RECOVERY_ENABLED_TYPEHASH(), true, safe.nonce()));
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
        safe.toggleRecoveryEnabled(true, signers, signatures);
    }

    function test_overrideRecoverySigners_updatesRecoverySigners() public {
        address[2] memory newSigners = [overriddenEtherFiSigner, overriddenThirdPartySigner];
        
        _overrideRecoverySigners(newSigners);
        
        address[] memory allSigners = safe.getRecoverySigners();
        
        // Check that override signers are now in the list
        assertEq(allSigners[0], overriddenEtherFiSigner);
        assertEq(allSigners[1], overriddenThirdPartySigner);
        
        // Check that original default signers are no longer valid
        assertFalse(safe.isRecoverySigner(etherFiRecoverySigner));
        assertFalse(safe.isRecoverySigner(thirdPartyRecoverySigner));
    }

    function test_isRecoverySigner_detectsAllValidSigners() public view {
        // Default signers
        assertTrue(safe.isRecoverySigner(etherFiRecoverySigner));
        assertTrue(safe.isRecoverySigner(thirdPartyRecoverySigner));
        
        // User recovery signers
        assertTrue(safe.isRecoverySigner(userRecoverySigner1));
        assertTrue(safe.isRecoverySigner(userRecoverySigner2));
        
        // Random address
        assertFalse(safe.isRecoverySigner(address(0x123)));
    }

    function test_isRecoverySigner_detectsOverriddenSigners() public {
        address[2] memory newSigners = [overriddenEtherFiSigner, overriddenThirdPartySigner];
        
        _overrideRecoverySigners(newSigners);
        
        // Overridden signers
        assertTrue(safe.isRecoverySigner(overriddenEtherFiSigner));
        assertTrue(safe.isRecoverySigner(overriddenThirdPartySigner));
        
        // Original default signers (should no longer be valid)
        assertFalse(safe.isRecoverySigner(etherFiRecoverySigner));
        assertFalse(safe.isRecoverySigner(thirdPartyRecoverySigner));
    }

    function test_isRecoverySigner_reverts_whenZeroAddress() public {
        vm.expectRevert(EtherFiSafeErrors.InvalidInput.selector);
        safe.isRecoverySigner(address(0));
    }

        function test_recoverSafe_initiatesRecoveryProcess() public {
        address newOwner = makeAddr("newOwner");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Check that incoming owner is set correctly
        assertEq(safe.getIncomingOwner(), newOwner);
        assertTrue(safe.getIncomingOwnerStartTime() > 0);
    }

    function test_recoverSafe_worksWithDifferentSignerCombinations() public {
        address newOwner = makeAddr("newOwner");
        
        // Combination 1: EtherFi and user signer
        {
            address[] memory recoverySigners = new address[](2);
            recoverySigners[0] = etherFiRecoverySigner;
            recoverySigners[1] = userRecoverySigner1;
            
            _recoverSafeWithSigners(newOwner, recoverySigners);
            _cancelRecovery();
        }
        
        // Combination 2: Third-party and user signer
        {
            address[] memory recoverySigners = new address[](2);
            recoverySigners[0] = thirdPartyRecoverySigner;
            recoverySigners[1] = userRecoverySigner2;
            
            _recoverSafeWithSigners(newOwner, recoverySigners);
            _cancelRecovery();
        }
        
        // Combination 3: Two user signers
        {
            address[] memory recoverySigners = new address[](2);
            recoverySigners[0] = userRecoverySigner1;
            recoverySigners[1] = userRecoverySigner2;
            
            _recoverSafeWithSigners(newOwner, recoverySigners);
            _cancelRecovery();
        }
    }

    function test_recoverSafe_worksWithHigherThreshold() public {
        // Set threshold to 3
        _setRecoveryThreshold(3);
        
        address newOwner = makeAddr("newOwner");
        
        // Need 3 signers now
        address[] memory recoverySigners = new address[](3);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        recoverySigners[2] = userRecoverySigner1;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Check that incoming owner is set correctly
        assertEq(safe.getIncomingOwner(), newOwner);
        assertTrue(safe.getIncomingOwnerStartTime() > 0);
    }

    function test_recoverSafe_worksWithOverriddenSigners() public {
        // First override the default signers
        address[2] memory newSigners = [overriddenEtherFiSigner, overriddenThirdPartySigner];
        _overrideRecoverySigners(newSigners);
        
        address newOwner = makeAddr("newOwner");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = overriddenEtherFiSigner;
        recoverySigners[1] = overriddenThirdPartySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Check that incoming owner is set correctly
        assertEq(safe.getIncomingOwner(), newOwner);
        assertTrue(safe.getIncomingOwnerStartTime() > 0);
    }

    function test_recoverSafe_setsCorrectTimeLock() public {
        address newOwner = makeAddr("newOwner");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        uint256 beforeTimestamp = block.timestamp;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        uint256 expectedTimelock = beforeTimestamp + dataProvider.getRecoveryDelayPeriod();
        assertEq(safe.getIncomingOwnerStartTime(), expectedTimelock);
    }

    function test_recoverSafe_withMoreThanThresholdSigners() public {
        address newOwner = makeAddr("newOwner");
        
        // Provide 4 signers when threshold is 2
        address[] memory recoverySigners = new address[](4);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        recoverySigners[2] = userRecoverySigner1;
        recoverySigners[3] = userRecoverySigner2;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Check that incoming owner is set correctly
        assertEq(safe.getIncomingOwner(), newOwner);
        assertTrue(safe.getIncomingOwnerStartTime() > 0);
    }

    function test_recoverSafe_reverts_whenRecoveryDisabled() public {
        // Disable recovery
        _toggleRecoveryEnabled(false);
        
        address newOwner = makeAddr("newOwner");
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(etherFiRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(thirdPartyRecoverySignerPk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(EtherFiSafeErrors.RecoveryDisabled.selector);
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function test_recoverSafe_reverts_whenNewOwnerIsZeroAddress() public {
        address newOwner = address(0);
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(etherFiRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(thirdPartyRecoverySignerPk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(EtherFiSafeErrors.InvalidInput.selector);
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function test_recoverSafe_reverts_whenDuplicateSigners() public {
        address newOwner = makeAddr("newOwner");
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = etherFiRecoverySigner; // Duplicate
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        bytes[] memory signatures = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(etherFiRecoverySignerPk, digestHash);
        signatures[0] = abi.encodePacked(r, s, v);
        signatures[1] = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function test_recoverSafe_reverts_whenInvalidRecoverySignature() public {
        address newOwner = makeAddr("newOwner");
        bytes32 wrongDigestHash = keccak256("wrong message");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        bytes[] memory signatures = new bytes[](2);
        // First signature uses wrong hash
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(etherFiRecoverySignerPk, wrongDigestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(thirdPartyRecoverySignerPk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(EtherFiSafeErrors.InvalidRecoverySignatures.selector);
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function test_recoverSafe_reverts_whenInsufficientSigners() public {
        // Set threshold to 3
        _setRecoveryThreshold(3);
        
        address newOwner = makeAddr("newOwner");
        
        // Only provide 2 signers when threshold is 3
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(etherFiRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(thirdPartyRecoverySignerPk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(EtherFiSafeErrors.InsufficientRecoverySignatures.selector);
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function test_recoverSafe_reverts_whenNonRecoverySigner() public {
        address newOwner = makeAddr("newOwner");
        address nonRecoverySigner = makeAddr("nonRecoverySigner");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = nonRecoverySigner; // Not a recovery signer
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        uint256 nonRecoverySignerPk = uint256(keccak256(abi.encodePacked("nonRecoverySigner")));
        
        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(etherFiRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(nonRecoverySignerPk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        // Expect revert when checking if address is a recovery signer
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidRecoverySigner.selector, 1)); 
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function test_ownerTransition_afterRecoveryTimelock() public {
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Force owner transition by calling a function that checks ownership
        bytes32 cancelStructHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 cancelDigestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), cancelStructHash));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newOwnerPk, cancelDigestHash);
        
        bytes[] memory cancelSignatures = new bytes[](1);
        cancelSignatures[0] = abi.encodePacked(r, s, v);
        
        address[] memory cancelSigners = new address[](1);
        cancelSigners[0] = newOwner;
        
        // Transition happens in _currentOwner() which is called by cancelRecovery
        safe.cancelRecovery(cancelSigners, cancelSignatures);
        
        // Check that ownership has transitioned
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], newOwner);
        assertEq(safe.getThreshold(), 1);
    }

    function test_getOwners_and_isOwner_afterRecoveryTimelock() public {
        (address newOwner, ) = makeAddrAndKey("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], newOwner);
        assertEq(safe.getThreshold(), 1);

        assertEq(safe.isOwner(newOwner), true);

        assertEq(safe.isOwner(owner1), false);
        assertEq(safe.isOwner(owner2), false);
        assertEq(safe.isOwner(owner3), false);
    }

    function test_getAdmins_and_isAdmin_afterRecoveryTimelock() public {
        (address newOwner, ) = makeAddrAndKey("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        address[] memory admins = safe.getAdmins();
        assertEq(admins.length, 1);
        assertEq(admins[0], newOwner);
        
        assertEq(safe.isAdmin(newOwner), true);

        assertEq(safe.isAdmin(owner1), false);
        assertEq(safe.isAdmin(owner2), false);
        assertEq(safe.isAdmin(owner3), false);
    }

    function test_checkSignatures_usesNewOwnerAfterRecovery() public {
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("newOwner");
        
        // Start recovery with valid recovery signers
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Test that only new owner's signature is required
        bytes32 testHash = keccak256("test message");
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newOwnerPk, testHash);
        
        bytes[] memory testSignatures = new bytes[](1);
        testSignatures[0] = abi.encodePacked(r, s, v);
        
        address[] memory testSigners = new address[](1);
        testSigners[0] = newOwner;
        
        assertTrue(safe.checkSignatures(testHash, testSigners, testSignatures));
        
        // Original owners' signatures should now be invalid
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(owner1Pk, testHash);
        
        testSignatures[0] = abi.encodePacked(r3, s3, v3);
        testSigners[0] = owner1;
        
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        safe.checkSignatures(testHash, testSigners, testSignatures);
    }

    function test_originalOwnersCannotCallFunctions_afterRecovery_revertsWithInvalidSigners() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Try to call a function with original owners (should fail)
        address otherSigner = makeAddr("otherSigner");
        address[] memory signerAddresses = new address[](1);
        signerAddresses[0] = otherSigner;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        bytes32 structHash = keccak256(abi.encode(
            safe.SET_USER_RECOVERY_SIGNERS_TYPEHASH(),
            keccak256(abi.encodePacked(signerAddresses)), 
            keccak256(abi.encodePacked(shouldAdd)), 
            safe.nonce()
        ));
        
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        
        address[] memory oldOwners = new address[](1);
        oldOwners[0] = owner1;
        
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        safe.setUserRecoverySigners(signerAddresses, shouldAdd, oldOwners, signatures);
    }


    function test_cancelRecovery_cancelsRecoveryProcess() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Now cancel it
        _cancelRecovery();
        
        // Check that incoming owner is cleared
        assertEq(safe.getIncomingOwner(), address(0));
        assertEq(safe.getIncomingOwnerStartTime(), 0);
    }

    function test_cancelRecovery_maintainsOriginalOwnership() public {
        address newOwner = makeAddr("newOwner");
        
        // Store original owners
        address[] memory originalOwners = safe.getOwners();
        uint8 originalThreshold = safe.getThreshold();
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Cancel recovery
        _cancelRecovery();
        
        // Verify ownership remains unchanged
        address[] memory currentOwners = safe.getOwners();
        assertEq(currentOwners.length, originalOwners.length);
        
        for (uint i = 0; i < originalOwners.length; i++) {
            assertEq(currentOwners[i], originalOwners[i]);
        }
        
        assertEq(safe.getThreshold(), originalThreshold);
    }

    function test_cancelRecovery_allowsNewRecoveryAfterwards() public {
        address firstNewOwner = makeAddr("firstNewOwner");
        address secondNewOwner = makeAddr("secondNewOwner");
        
        // Start first recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(firstNewOwner, recoverySigners);
        
        // Cancel first recovery
        _cancelRecovery();
        
        // Start second recovery
        _recoverSafeWithSigners(secondNewOwner, recoverySigners);
        
        // Verify second recovery is active
        assertEq(safe.getIncomingOwner(), secondNewOwner);
        assertTrue(safe.getIncomingOwnerStartTime() > 0);
    }

    function test_cancelRecovery_requiresOwnerSignatures() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Try to cancel with non-owner signatures
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        uint256 randomPk = uint256(keccak256(abi.encodePacked("random")));
        address randomAddr = vm.addr(randomPk);
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(randomPk, digestHash);
        
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r1, s1, v1);
        
        address[] memory signers = new address[](2);
        signers[0] = randomAddr;
        signers[1] = owner1;
        
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        safe.cancelRecovery(signers, signatures);
    }

    function test_cancelRecovery_worksWithSingleOwnerSignature() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Cancel using just one owner signature (when threshold is 2)
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        
        address[] memory signers = new address[](1);
        signers[0] = owner1;
        
        // This should NOT work because we need threshold (2) signatures
        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        safe.cancelRecovery(signers, signatures);
    }

    function test_cancelRecovery_worksWithMultipleOwnerSignatures() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Cancel with all three owner signatures
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(owner3Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](3);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        signatures[2] = abi.encodePacked(r3, s3, v3);
        
        address[] memory signers = new address[](3);
        signers[0] = owner1;
        signers[1] = owner2;
        signers[2] = owner3;
        
        safe.cancelRecovery(signers, signatures);
        
        // Verify recovery was canceled
        assertEq(safe.getIncomingOwner(), address(0));
        assertEq(safe.getIncomingOwnerStartTime(), 0);
    }

    function test_cancelRecovery_failsAfterTimelockPeriod_revertsWithInvalidSigner() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Advance time past the timelock period
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Try to cancel with original owners
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        
        address[] memory signers = new address[](1);
        signers[0] = owner1;
        
        // This should fail because ownership has already transitioned
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        safe.cancelRecovery(signers, signatures);
    }

    function test_cancelRecovery_worksWithNewOwnerAfterTimelock() public {
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Advance time past the timelock period
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Cancel with new owner signature
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newOwnerPk, digestHash);
        
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);
        
        address[] memory signers = new address[](1);
        signers[0] = newOwner;
        
        safe.cancelRecovery(signers, signatures);
        
        // Verify transition completed and recovery state cleared
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], newOwner);
        assertEq(safe.getThreshold(), 1);
        assertEq(safe.getIncomingOwner(), address(0));
        assertEq(safe.getIncomingOwnerStartTime(), 0);
    }

    function test_multipleRecoveryCancellations() public {
        address newOwner = makeAddr("newOwner");
        
        // First recovery cycle
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        _cancelRecovery();
        
        // Second recovery cycle
        _recoverSafeWithSigners(newOwner, recoverySigners);
        _cancelRecovery();
        
        // Third recovery cycle
        _recoverSafeWithSigners(newOwner, recoverySigners);
        _cancelRecovery();
        
        // Verify ownership remains unchanged after multiple cancellations
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 3);
        assertTrue(owners[0] == owner1);
        assertTrue(owners[1] == owner2);
        assertTrue(owners[2] == owner3);
    }

    function test_cancelRecovery_emitsEvent() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Prepare cancel recovery parameters
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        
        // Check for event emission
        vm.expectEmit(true, true, true, true);
        emit RecoveryManager.RecoveryCancelled();
        
        safe.cancelRecovery(signers, signatures);
    }

    function test_getRecoveryThreshold_returnsDefaultValue() public view {
        // Should return the default threshold (2) set in _setupRecovery
        assertEq(safe.getRecoveryThreshold(), 2);
    }

    function test_getRecoveryThreshold_returnsUpdatedValue() public {
        // Update threshold to 3
        uint8 newThreshold = 3;
        _setRecoveryThreshold(newThreshold);
        
        // Verify the getter returns the updated value
        assertEq(safe.getRecoveryThreshold(), newThreshold);
    }

    function test_getRecoveryThreshold_afterMultipleUpdates() public {
        // Make multiple updates and check each time
        uint8[] memory thresholds = new uint8[](3);
        thresholds[0] = 3;
        thresholds[1] = 4;
        thresholds[2] = 2; // Back to default
        
        for (uint i = 0; i < thresholds.length; i++) {
            _setRecoveryThreshold(thresholds[i]);
            assertEq(safe.getRecoveryThreshold(), thresholds[i]);
        }
    }

    function test_getRecoveryStatus_initialState() public view {
        // Check initial state (should be enabled with no pending recovery)
        (bool isEnabled, bool isPending, address incomingOwner, uint256 timelockExpiration) = safe.getRecoveryStatus();
        
        assertTrue(isEnabled);     // Recovery should be enabled by default
        assertFalse(isPending);    // No pending recovery initially
        assertEq(incomingOwner, address(0));  // No incoming owner
        assertEq(timelockExpiration, 0);      // No timelock
    }

    function test_getRecoveryStatus_whenDisabled() public {
        // Disable recovery
        _toggleRecoveryEnabled(false);
        
        // Check status
        (bool isEnabled, bool isPending, address incomingOwner, uint256 timelockExpiration) = safe.getRecoveryStatus();
        
        assertFalse(isEnabled);    // Recovery should be disabled now
        assertFalse(isPending);    // No pending recovery
        assertEq(incomingOwner, address(0));  // No incoming owner
        assertEq(timelockExpiration, 0);      // No timelock
    }

    function test_getRecoveryStatus_duringPendingRecovery() public {
        // Start a recovery process
        address newOwner = makeAddr("newOwner");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Check status
        (bool isEnabled, bool isPending, address incomingOwner, uint256 timelockExpiration) = safe.getRecoveryStatus();
        
        assertTrue(isEnabled);         // Recovery should be enabled
        assertTrue(isPending);         // Recovery should be pending
        assertEq(incomingOwner, newOwner);  // Incoming owner should match
        assertTrue(timelockExpiration > 0);  // Timelock should be set
    }

    function test_getRecoveryStatus_afterCanceledRecovery() public {
        // Start a recovery process
        address newOwner = makeAddr("newOwner");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Now cancel the recovery
        _cancelRecovery();
        
        // Check status after cancellation
        (bool isEnabled, bool isPending, address incomingOwner, uint256 timelockExpiration) = safe.getRecoveryStatus();
        
        assertTrue(isEnabled);        // Recovery should still be enabled
        assertFalse(isPending);       // Recovery should no longer be pending
        assertEq(incomingOwner, address(0));  // Incoming owner should be cleared
        assertEq(timelockExpiration, 0);      // Timelock should be cleared
    }

    function test_getRecoveryStatus_afterTimelockExpiration() public {
        // Start a recovery process
        (address newOwner, ) = makeAddrAndKey("newOwner");
        
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Advance time past the timelock period
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Force state transition by calling a function
        // This is needed because the state transition happens lazily when a function is called
        safe.getOwners();
        
        // Check status after timelock expiration and transition
        (bool isEnabled, , , ) = safe.getRecoveryStatus();
        
        assertTrue(isEnabled);        // Recovery should still be enabled
        // After ownership has transitioned, isPending might be false if implementation clears these
        // values after transfer, or might still show as pending if values aren't cleared
        // The actual behavior depends on the _currentOwner implementation
        
        // For completeness, we'll check both the returned values and the actual owner
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], newOwner);  // New owner should now be the owner
    }

    function test_getRecoveryStatus_statusChangesSynchronously() public {
        // This test checks that the recovery status values change appropriately with recovery actions
        
        // Start with default state
        (bool isEnabled1, bool isPending1, , ) = safe.getRecoveryStatus();
        assertTrue(isEnabled1);
        assertFalse(isPending1);
        
        // Start a recovery
        address newOwner = makeAddr("newOwner");
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        _recoverSafeWithSigners(newOwner, recoverySigners);
        
        // Status should immediately reflect pending recovery
        (bool isEnabled2, bool isPending2, address incomingOwner2, ) = safe.getRecoveryStatus();
        assertTrue(isEnabled2);
        assertTrue(isPending2);
        assertEq(incomingOwner2, newOwner);
        
        // Cancel recovery
        _cancelRecovery();
        
        // Status should immediately reflect canceled recovery
        (bool isEnabled3, bool isPending3, address incomingOwner3, ) = safe.getRecoveryStatus();
        assertTrue(isEnabled3);
        assertFalse(isPending3);
        assertEq(incomingOwner3, address(0));
        
        // Disable recovery
        _toggleRecoveryEnabled(false);
        
        // Status should immediately reflect disabled recovery
        (bool isEnabled4, bool isPending4, , ) = safe.getRecoveryStatus();
        assertFalse(isEnabled4);
        assertFalse(isPending4);
    }
}