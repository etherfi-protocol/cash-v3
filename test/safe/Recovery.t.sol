// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "./SafeTestSetup.t.sol";

contract RecoveryManagerTest is SafeTestSetup {
    uint256 userRecoverySignerPk;
    address userRecoverySigner;

    function setUp() public override {
        super.setUp();
        
        // Create a user recovery signer
        (userRecoverySigner, userRecoverySignerPk) = makeAddrAndKey("userRecoverySigner");
        
        // Set the user recovery signer
        _setUserRecoverySigner(userRecoverySigner);
    }

    function test_isRecoveryEnabled_defaultsToTrue() public view {
        // Recovery should be enabled during setup
        assertTrue(safe.isRecoveryEnabled());
    }

    function test_setUserRecoverySigner_updatesRecoverySigner() public {
        address newSigner = makeAddr("newRecoverySigner");
        _setUserRecoverySigner(newSigner);
        
        (address userSigner, ,) = safe.getRecoverySigners();
        assertEq(userSigner, newSigner);
    }

    function test_setUserRecoverySigner_reverts_whenSignerIsZeroAddress() public {
        address newSigner = address(0);

        bytes32 structHash = keccak256(abi.encode(safe.SET_USER_RECOVERY_SIGNER_TYPEHASH(), newSigner, safe.nonce()));
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
        safe.setUserRecoverySigner(newSigner, signers, signatures);
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
        address newEtherFiSigner = makeAddr("newEtherFiSigner");
        address newThirdPartySigner = makeAddr("newThirdPartySigner");
        
        _overrideRecoverySigners(newEtherFiSigner, newThirdPartySigner);
        
        (, address etherFiSigner, address thirdPartySigner) = safe.getRecoverySigners();
        assertEq(etherFiSigner, newEtherFiSigner);
        assertEq(thirdPartySigner, newThirdPartySigner);
    }

    function test_getRecoverySigners_returnsCorrectSigners() public view {
        (address userSigner, address etherFiSigner, address thirdPartySigner) = safe.getRecoverySigners();
        
        assertEq(userSigner, userRecoverySigner);
        assertEq(etherFiSigner, etherFiRecoverySigner);
        assertEq(thirdPartySigner, thirdPartyRecoverySigner);
    }

    function test_recoverSafe_initiatesRecoveryProcess() public {
        address newOwner = makeAddr("newOwner");
        
        _recoverSafe(newOwner, 0, 1); // User signer and EtherFi signer
        
        // Check that incoming owner is set correctly
        assertEq(safe.getIncomingOwner(), newOwner);
        assertTrue(safe.getIncomingOwnerStartTime() > 0);
    }

    function test_recoverSafe_reverts_whenRecoveryDisabled() public {
        address newOwner = makeAddr("newOwner");
        
        // Disable recovery
        _toggleRecoveryEnabled(false);
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(etherFiRecoverySignerPk, digestHash);
        
        bytes[2] memory signatures;
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        uint256[2] memory recoverySignerIndices = [uint256(0), uint256(1)];
        
        vm.expectRevert(EtherFiSafeErrors.RecoveryDisabled.selector);
        safe.recoverSafe(newOwner, recoverySignerIndices, signatures);
    }

    function test_recoverSafe_reverts_whenUserRecoverySignerNotSet() public {
        address newOwner = makeAddr("newOwner");
        
        // Create a safe without a user recovery signer setup
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;

        address[] memory modules = new address[](1);
        modules[0] = module1;

        vm.prank(owner);
        safeFactory.deployEtherFiSafe(keccak256("safe2"), owners, modules, new bytes[](1), 1);
        EtherFiSafe newSafe = EtherFiSafe(safeFactory.getDeterministicAddress(keccak256("safe2")));
        
        bytes32 structHash = keccak256(abi.encode(newSafe.RECOVER_SAFE_TYPEHASH(), newOwner, newSafe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", newSafe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(etherFiRecoverySignerPk, digestHash);
        
        bytes[2] memory signatures;
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        uint256[2] memory recoverySignerIndices = [uint256(0), uint256(1)];
        
        vm.expectRevert(EtherFiSafeErrors.InvalidUserRecoverySigner.selector);
        newSafe.recoverSafe(newOwner, recoverySignerIndices, signatures);
    }

    function test_recoverSafe_reverts_whenSignerIndexInvalid() public {
        address newOwner = makeAddr("newOwner");
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userRecoverySignerPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(etherFiRecoverySignerPk, digestHash);
        
        bytes[2] memory signatures;
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        // Use invalid index 3
        uint256[2] memory recoverySignerIndices = [uint256(3), uint256(1)];
        
        vm.expectRevert(EtherFiSafeErrors.InvalidInput.selector);
        safe.recoverSafe(newOwner, recoverySignerIndices, signatures);
    }

    function test_recoverSafe_reverts_whenSignatureInvalid() public {
        address newOwner = makeAddr("newOwner");
        
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 wrongHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), address(0), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        bytes32 wrongDigestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), wrongHash));
        
        // Sign with wrong hash
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userRecoverySignerPk, wrongDigestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(etherFiRecoverySignerPk, digestHash);
        
        bytes[2] memory signatures;
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        uint256[2] memory recoverySignerIndices = [uint256(0), uint256(1)];
        
        vm.expectRevert(EtherFiSafeErrors.InvalidRecoverySignature.selector);
        safe.recoverSafe(newOwner, recoverySignerIndices, signatures);
    }

    function test_recoverSafe_allowsDifferentSignerCombinations() public {
        address newOwner = makeAddr("newOwner");
        
        // User signer and third-party signer
        _recoverSafe(newOwner, 0, 2);
        _cancelRecovery();
        
        // EtherFi signer and third-party signer
        _recoverSafe(newOwner, 1, 2);
    }

    function test_cancelRecovery_cancelsRecoveryProcess() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        _recoverSafe(newOwner, 0, 1);
        
        // Now cancel it
        _cancelRecovery();
        
        // Check that incoming owner is cleared
        assertEq(safe.getIncomingOwner(), address(0));
        assertEq(safe.getIncomingOwnerStartTime(), 0);
    }

    function test_ownerTransition_afterRecoveryTimelock() public {
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("newOwner");
        
        // Start recovery
        _recoverSafe(newOwner, 0, 1);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Force owner transition by calling a function that checks ownership
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newOwnerPk, digestHash);
        
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);
        
        address[] memory signers = new address[](1);
        signers[0] = newOwner;
        
        // Transition happens in _currentOwner() which is called by cancelRecovery
        safe.cancelRecovery(signers, signatures);
        
        // Check that ownership has transitioned
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], newOwner);
        assertEq(safe.getThreshold(), 1);
    }

    function test_checkSignatures_usesNewOwnerAfterRecovery() public {
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("newOwner");
        
        // Start recovery
        _recoverSafe(newOwner, 0, 1);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Test that only new owner's signature is required
        bytes32 testHash = keccak256("test message");
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newOwnerPk, testHash);
        
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);
        
        address[] memory signers = new address[](1);
        signers[0] = newOwner;
        
        assertTrue(safe.checkSignatures(testHash, signers, signatures));
        
        // Original owners' signatures should now be invalid
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, testHash);
        
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signers[0] = owner1;
        
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        safe.checkSignatures(testHash, signers, signatures);
    }

    function test_cancelRecovery_reverts_withInvalidInput_afterTimelock() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        _recoverSafe(newOwner, 0, 1);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Try to cancel recovery with original owners (should fail)
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
        
        vm.expectRevert(EtherFiSafeErrors.InvalidInput.selector);
        safe.cancelRecovery(signers, signatures);
    }

    function test_cancelRecovery_reverts_withInvalidSigner_afterTimelock() public {
        address newOwner = makeAddr("newOwner");
        
        // Start recovery
        _recoverSafe(newOwner, 0, 1);
        
        // Mock timelock passage
        uint256 delayPeriod = dataProvider.getRecoveryDelayPeriod();
        vm.warp(block.timestamp + delayPeriod + 1);
        
        // Try to cancel recovery with original owners (should fail)
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        
        address[] memory signers = new address[](1);
        signers[0] = owner1;
        
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 0));
        safe.cancelRecovery(signers, signatures);
    }

    // Helper functions
    function _setUserRecoverySigner(address signer) internal {
        bytes32 structHash = keccak256(abi.encode(safe.SET_USER_RECOVERY_SIGNER_TYPEHASH(), signer, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.setUserRecoverySigner(signer, signers, signatures);
    }

    function _toggleRecoveryEnabled(bool shouldEnable) internal {
        bytes32 structHash = keccak256(abi.encode(safe.TOGGLE_RECOVERY_ENABLED_TYPEHASH(), shouldEnable, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.toggleRecoveryEnabled(shouldEnable, signers, signatures);
    }

    function _overrideRecoverySigners(address etherFiSigner, address thirdPartySigner) internal {
        address[2] memory recoverySigners = [etherFiSigner, thirdPartySigner];
        
        bytes32 structHash = keccak256(abi.encode(safe.OVERRIDE_RECOVERY_SIGNERS_TYPEHASH(), recoverySigners, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.overrideRecoverySigners(recoverySigners, signers, signatures);
    }

    function _recoverSafe(address newOwner, uint256 signerIndex1, uint256 signerIndex2) internal {
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(_getSignerPk(signerIndex1), digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(_getSignerPk(signerIndex2), digestHash);
        
        bytes[2] memory signatures = [abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2)]; 
        
        uint256[2] memory recoverySignerIndices = [signerIndex1, signerIndex2];
        
        safe.recoverSafe(newOwner, recoverySignerIndices, signatures);
    }

    function _getSignerPk(uint256 index) internal view returns (uint256) {
        if (index == 0) return userRecoverySignerPk;
        else if (index == 1) return etherFiRecoverySignerPk;
        else return thirdPartyRecoverySignerPk;
    }

    function _cancelRecovery() internal {
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

        safe.cancelRecovery(signers, signatures);
    }
}