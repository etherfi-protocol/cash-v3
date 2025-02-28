// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, ModuleBase } from "./SafeTestSetup.t.sol";

contract SafeAdminsTest is SafeTestSetup {
    address public admin1;
    address public admin2;
    address public nonAdmin;
        
    function setUp() public override {
        super.setUp();
        
        admin1 = makeAddr("admin1");
        admin2 = makeAddr("admin2");
        nonAdmin = makeAddr("nonAdmin");
    }
    
    function test_configureAdmins_addsAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = admin1;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        _configureAdmins(accounts, shouldAdd);
        
        // Verify admin was added
        assertTrue(safe.isAdmin(admin1), "Account should be admin after adding");
    }
    
    function test_configureAdmins_removesAdmin() public {
        // First add the admin
        address[] memory accounts = new address[](1);
        accounts[0] = admin1;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        _configureAdmins(accounts, shouldAdd);
        
        // Now remove the admin
        shouldAdd[0] = false;
        
        bytes32 structHash = keccak256(abi.encode(
            safe.CONFIGURE_ADMIN_TYPEHASH(),
            keccak256(abi.encodePacked(accounts)),
            keccak256(abi.encodePacked(shouldAdd)),
            safe.nonce()
        ));
        
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        
        vm.expectEmit(true, true, true, true);
        emit EtherFiSafe.AdminsConfigured(accounts, shouldAdd);
        
        safe.configureAdmins(accounts, shouldAdd, signers, signatures);
        
        // Verify admin was removed
        assertFalse(safe.isAdmin(admin1), "Account should not be admin after removing");
    }
    
    function test_configureAdmins_reverts_withInvalidSignatures() public {
        address[] memory accounts = new address[](1);
        accounts[0] = admin1;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        bytes32 structHash = keccak256(abi.encode(
            safe.CONFIGURE_ADMIN_TYPEHASH(),
            keccak256(abi.encodePacked(accounts)),
            keccak256(abi.encodePacked(shouldAdd)),
            safe.nonce()
        ));
        
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        // Sign with wrong private key (owner2) and send owner3 signer
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner3;
        
        vm.expectRevert(EtherFiSafeErrors.InvalidSignatures.selector);
        safe.configureAdmins(accounts, shouldAdd, signers, signatures);
    }
    
    function test_configureAdmins_addsMultipleAdmins() public {
        address[] memory accounts = new address[](2);
        accounts[0] = admin1;
        accounts[1] = admin2;
        
        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = true;
        shouldAdd[1] = true;
        
        _configureAdmins(accounts, shouldAdd);
        
        // Verify both admins were added
        assertTrue(safe.isAdmin(admin1), "First account should be admin");
        assertTrue(safe.isAdmin(admin2), "Second account should be admin");
    }
    
    function test_getAdmins_returnsAllAdmins() public {
        // Initially owners are admins due to initialization
        address[] memory initialAdmins = safe.getAdmins();
        
        assertEq(initialAdmins.length, 3, "Should have 3 initial admins (owners)");
        
        // Add two more admins
        address[] memory accounts = new address[](2);
        accounts[0] = admin1;
        accounts[1] = admin2;
        
        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = true;
        shouldAdd[1] = true;
        
        _configureAdmins(accounts, shouldAdd);
        
        // Get all admins
        address[] memory allAdmins = safe.getAdmins();
        
        assertEq(allAdmins.length, 5, "Should have 5 admins after adding 2");
        
        // Verify the new admins are in the list
        bool admin1Found = false;
        bool admin2Found = false;
        
        for (uint256 i = 0; i < allAdmins.length; i++) {
            if (allAdmins[i] == admin1) admin1Found = true;
            if (allAdmins[i] == admin2) admin2Found = true;
        }
        
        assertTrue(admin1Found, "Admin1 should be in the list");
        assertTrue(admin2Found, "Admin2 should be in the list");
    }
    
    function test_isAdmin_returnsCorrectStatus() public {
        // Add an admin
        address[] memory accounts = new address[](1);
        accounts[0] = admin1;
        
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;
        
        _configureAdmins(accounts, shouldAdd);
        
        // Check statuses
        assertTrue(safe.isAdmin(admin1), "Admin1 should be an admin");
        assertFalse(safe.isAdmin(nonAdmin), "NonAdmin should not be an admin");
        assertTrue(safe.isAdmin(owner1), "Owner1 should be an admin (from initialization)");
    }
}