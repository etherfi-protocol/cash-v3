// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode } from "../../../../src/interfaces/ICashModule.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { CashEventEmitter, CashModuleTestSetup, CashVerificationLib, ICashModule, IDebtManager, MessageHashUtils } from "./CashModuleTestSetup.t.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol"; 
import { EnumerableAddressWhitelistLib } from "../../../../src/libraries/EnumerableAddressWhitelistLib.sol";

contract CashModuleConfigureWithdrawRecipientsTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    address public otherRecipient = makeAddr("otherRecipient");
    address public thirdRecipient = makeAddr("thirdRecipient");

    function setUp() public override {
        super.setUp();
        
        // Clear any existing recipients to make tests more predictable
        address[] memory existingRecipients = cashModule.getWithdrawRecipients(address(safe));
        if (existingRecipients.length > 0) {
            bool[] memory shouldRemove = new bool[](existingRecipients.length);
            for (uint i = 0; i < shouldRemove.length; i++) {
                shouldRemove[i] = false;
            }
            _configureWithdrawRecipients(existingRecipients, shouldRemove);
        }
    }

    function test_configureWithdrawRecipients_add_single_recipient() public {
        // Add a single recipient
        address[] memory recipients = new address[](1);
        recipients[0] = withdrawRecipient;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        _configureWithdrawRecipients(recipients, shouldAdd);
        
        // Verify recipient was added
        address[] memory configuredRecipients = cashModule.getWithdrawRecipients(address(safe));
        assertEq(configuredRecipients.length, 1);
        assertEq(configuredRecipients[0], withdrawRecipient);
        
        // Check isWhitelisted function
        assertTrue(cashModule.isWhitelistedWithdrawRecipient(address(safe), withdrawRecipient));
        assertFalse(cashModule.isWhitelistedWithdrawRecipient(address(safe), otherRecipient));
    }
    
    function test_configureWithdrawRecipients_add_multiple_recipients() public {
        // Add multiple recipients
        address[] memory recipients = new address[](3);
        recipients[0] = withdrawRecipient;
        recipients[1] = otherRecipient;
        recipients[2] = thirdRecipient;
        
        bool[] memory shouldAdd = new bool[](3);
        shouldAdd[0] = true;
        shouldAdd[1] = true;
        shouldAdd[2] = true;
        
        _configureWithdrawRecipients(recipients, shouldAdd);
        
        // Verify all recipients were added
        address[] memory configuredRecipients = cashModule.getWithdrawRecipients(address(safe));
        assertEq(configuredRecipients.length, 3);
        
        // Check that all recipients are whitelisted
        assertTrue(cashModule.isWhitelistedWithdrawRecipient(address(safe), withdrawRecipient));
        assertTrue(cashModule.isWhitelistedWithdrawRecipient(address(safe), otherRecipient));
        assertTrue(cashModule.isWhitelistedWithdrawRecipient(address(safe), thirdRecipient));
    }
    
    function test_configureWithdrawRecipients_remove_recipient() public {
        // First add a recipient
        address[] memory addRecipients = new address[](1);
        addRecipients[0] = withdrawRecipient;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        _configureWithdrawRecipients(addRecipients, shouldAdd);
        
        // Verify recipient was added
        address[] memory configuredRecipients = cashModule.getWithdrawRecipients(address(safe));
        assertEq(configuredRecipients.length, 1);
        
        // Now remove the recipient
        bool[] memory shouldRemove = new bool[](1);
        shouldRemove[0] = false;
        
        _configureWithdrawRecipients(addRecipients, shouldRemove);
        
        // Verify recipient was removed
        configuredRecipients = cashModule.getWithdrawRecipients(address(safe));
        assertEq(configuredRecipients.length, 0);
        assertFalse(cashModule.isWhitelistedWithdrawRecipient(address(safe), withdrawRecipient));
    }
    
    function test_configureWithdrawRecipients_add_and_remove_in_single_txn() public {
        // Set up with initial recipient
        address[] memory initialRecipients = new address[](1);
        initialRecipients[0] = withdrawRecipient;
        
        bool[] memory initialShouldAdd = new bool[](1);
        initialShouldAdd[0] = true;
        
        _configureWithdrawRecipients(initialRecipients, initialShouldAdd);
        
        // Add one recipient and remove another in the same transaction
        address[] memory recipients = new address[](2);
        recipients[0] = withdrawRecipient;
        recipients[1] = otherRecipient;
        
        bool[] memory shouldModify = new bool[](2);
        shouldModify[0] = false; // Remove withdrawRecipient
        shouldModify[1] = true;  // Add otherRecipient
        
        _configureWithdrawRecipients(recipients, shouldModify);
        
        // Verify correct recipients are present
        address[] memory configuredRecipients = cashModule.getWithdrawRecipients(address(safe));
        assertEq(configuredRecipients.length, 1);
        assertEq(configuredRecipients[0], otherRecipient);
        
        assertFalse(cashModule.isWhitelistedWithdrawRecipient(address(safe), withdrawRecipient));
        assertTrue(cashModule.isWhitelistedWithdrawRecipient(address(safe), otherRecipient));
    }
    
    function test_configureWithdrawRecipients_idempotent_operations() public {
        // Adding twice doesn't change anything
        address[] memory recipients = new address[](1);
        recipients[0] = withdrawRecipient;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        // Add first time
        _configureWithdrawRecipients(recipients, shouldAdd);
        
        // Add second time (should be idempotent)
        _configureWithdrawRecipients(recipients, shouldAdd);
        
        // Verify only one entry exists
        address[] memory configuredRecipients = cashModule.getWithdrawRecipients(address(safe));
        assertEq(configuredRecipients.length, 1);
        assertEq(configuredRecipients[0], withdrawRecipient);
        
        // Removing a non-existent recipient shouldn't change anything
        address[] memory nonExistentRecipients = new address[](1);
        nonExistentRecipients[0] = thirdRecipient;
        
        bool[] memory shouldRemove = new bool[](1);
        shouldRemove[0] = false;
        
        _configureWithdrawRecipients(nonExistentRecipients, shouldRemove);
        
        // Verify the list is unchanged
        configuredRecipients = cashModule.getWithdrawRecipients(address(safe));
        assertEq(configuredRecipients.length, 1);
        assertEq(configuredRecipients[0], withdrawRecipient);
    }
    
    function test_configureWithdrawRecipients_fails_arrayLengthMismatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = withdrawRecipient;
        recipients[1] = otherRecipient;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        // Generate the signature
        uint256 nonce = safe.nonce();
        bytes32 digestHash = keccak256(abi.encodePacked(
            CashVerificationLib.CONFIGURE_WITHDRAWAL_RECIPIENT, 
            block.chainid, 
            address(safe), 
            nonce, 
            abi.encode(recipients, shouldAdd)
        )).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        // Should fail because recipients and shouldAdd arrays have different lengths
        vm.expectRevert(ModuleBase.ArrayLengthMismatch.selector);
        cashModule.configureWithdrawRecipients(address(safe), recipients, shouldAdd, signers, signatures);
    }
    
    function test_configureWithdrawRecipients_fails_invalidSignatures() public {
        address[] memory recipients = new address[](1);
        recipients[0] = withdrawRecipient;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        // Generate the signature
        uint256 nonce = safe.nonce();
        bytes32 digestHash = keccak256(abi.encodePacked(
            CashVerificationLib.CONFIGURE_WITHDRAWAL_RECIPIENT, 
            block.chainid, 
            address(safe), 
            nonce, 
            abi.encode(recipients, shouldAdd)
        )).toEthSignedMessageHash();

        // Use only one owner's signature when two are required
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        // since sig is from owner 1 and signers[1] = owner2, this is wrong signature
        signatures[1] = abi.encodePacked(r1, s1, v1);
        
        vm.expectRevert(CashVerificationLib.InvalidSignatures.selector);
        cashModule.configureWithdrawRecipients(address(safe), recipients, shouldAdd, signers, signatures);
    }
    
    function test_configureWithdrawRecipients_fails_wrongSigners() public {
        address[] memory recipients = new address[](1);
        recipients[0] = withdrawRecipient;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        // Generate the signature
        uint256 nonce = safe.nonce();
        bytes32 digestHash = keccak256(abi.encodePacked(
            CashVerificationLib.CONFIGURE_WITHDRAWAL_RECIPIENT, 
            block.chainid, 
            address(safe), 
            nonce, 
            abi.encode(recipients, shouldAdd)
        )).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(notOwnerPk, digestHash); // Not an owner

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        // signer1 is not an owner
        signers[1] = notOwner; // Not an owner

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        // Should fail because one of the signers is not an owner
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.InvalidSigner.selector, 1));
        cashModule.configureWithdrawRecipients(address(safe), recipients, shouldAdd, signers, signatures);
    }
    
    function test_configureWithdrawRecipients_with_zero_address() public {
        // Test behavior with zero address
        address[] memory recipients = new address[](1);
        recipients[0] = address(0);
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        uint256 nonce = safe.nonce();
        bytes32 digestHash = keccak256(abi.encodePacked(
            CashVerificationLib.CONFIGURE_WITHDRAWAL_RECIPIENT, 
            block.chainid, 
            address(safe), 
            nonce, 
            abi.encode(recipients, shouldAdd)
        )).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash); 

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(abi.encodeWithSelector(EnumerableAddressWhitelistLib.InvalidAddress.selector, 0));
        cashModule.configureWithdrawRecipients(address(safe), recipients, shouldAdd, signers, signatures);
    }
    
    function test_withdraw_after_recipient_configuration() public {
        // Add a recipient
        address[] memory recipients = new address[](1);
        recipients[0] = withdrawRecipient;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        _configureWithdrawRecipients(recipients, shouldAdd);
        
        // Set up a withdrawal
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;
        
        // Should succeed since recipient is whitelisted
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
                
        // Should fail with a different recipient that's not whitelisted
        deal(address(usdcScroll), address(safe), withdrawalAmount);
        
        uint256 nonce = safe.nonce();
        bytes32 digestHash = keccak256(abi.encodePacked(
            CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, 
            block.chainid, 
            address(safe), 
            nonce, 
            abi.encode(tokens, amounts, otherRecipient)
        )).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(ICashModule.OnlyWhitelistedWithdrawRecipients.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, otherRecipient, signers, signatures);
    }
    
    function test_empty_whitelist_allows_any_recipient() public {
        // Make sure whitelist is empty
        address[] memory existingRecipients = cashModule.getWithdrawRecipients(address(safe));
        if (existingRecipients.length > 0) {
            bool[] memory shouldRemove = new bool[](existingRecipients.length);
            for (uint i = 0; i < shouldRemove.length; i++) {
                shouldRemove[i] = false;
            }
            _configureWithdrawRecipients(existingRecipients, shouldRemove);
        }
        
        // Set up a withdrawal to any address
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;
        
        // Should succeed with any recipient when whitelist is empty
        _requestWithdrawal(tokens, amounts, makeAddr("randomRecipient"));
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);
    }
}