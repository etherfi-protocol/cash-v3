// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { EtherFiSafe, EtherFiSafeFactory, SafeTestSetup } from "./SafeTestSetup.t.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";

contract SafeFactoryTest is SafeTestSetup {
    address[] public owners;
    address[] public modules;
    bytes[] public moduleSetupData;
    uint8 public testThreshold = 2;
    bytes32 public salt = keccak256("newSafe");

    function setUp() public override {
        super.setUp();

        // Initialize owners for new safes
        owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        // Initialize modules for new safes
        modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        moduleSetupData = new bytes[](2);
    }

    function test_deployEtherFiSafe_succeeds() public {
        vm.startPrank(owner);

        // Deploy a new safe
        safeFactory.deployEtherFiSafe(salt, owners, modules, moduleSetupData, testThreshold);

        // Verify the safe was deployed correctly
        address payable deterministicAddress = payable(safeFactory.getDeterministicAddress(salt));
        assertTrue(safeFactory.isEtherFiSafe(deterministicAddress));

        // Check if the safe is properly initialized
        EtherFiSafe newSafe = EtherFiSafe(deterministicAddress);
        assertEq(newSafe.getThreshold(), testThreshold);

        // Verify owners
        assertTrue(newSafe.isOwner(owner1));
        assertTrue(newSafe.isOwner(owner2));
        assertTrue(newSafe.isOwner(owner3));
        assertFalse(newSafe.isOwner(notOwner));

        // Verify modules
        assertTrue(newSafe.isModuleEnabled(module1));
        assertTrue(newSafe.isModuleEnabled(module2));

        vm.stopPrank();
    }

    function test_deployEtherFiSafe_succeeds_withNoModules() public {
        vm.startPrank(owner);

        // Create empty modules array
        address[] memory noModules = new address[](0);
        bytes[] memory noModuleSetupData = new bytes[](0);
        bytes32 newSalt = keccak256("noModulesSafe");

        // Deploy a new safe with no modules
        safeFactory.deployEtherFiSafe(newSalt, owners, noModules, noModuleSetupData, testThreshold);

        // Verify the safe was deployed correctly
        address payable deterministicAddress = payable(safeFactory.getDeterministicAddress(newSalt));
        assertTrue(safeFactory.isEtherFiSafe(deterministicAddress));

        // Check if the safe has no modules
        EtherFiSafe newSafe = EtherFiSafe(deterministicAddress);
        assertFalse(newSafe.isModuleEnabled(module1));
        assertFalse(newSafe.isModuleEnabled(module2));

        vm.stopPrank();
    }

    function test_deployEtherFiSafe_reverts_whenCallerIsNotAdmin() public {
        vm.startPrank(notOwner);

        // Expect the deployment to revert because caller is not an admin
        vm.expectRevert(EtherFiSafeFactory.OnlyAdmin.selector);
        safeFactory.deployEtherFiSafe(salt, owners, modules, moduleSetupData, testThreshold);

        vm.stopPrank();
    }

    function test_deployEtherFiSafe_succeeds_forDifferentSalt() public {
        vm.startPrank(owner);

        // Deploy multiple safes with different salts
        for (uint256 i = 0; i < 3; i++) {
            bytes32 newSalt = keccak256(abi.encodePacked("safe", i));
            safeFactory.deployEtherFiSafe(newSalt, owners, modules, moduleSetupData, testThreshold);

            // Verify each safe was deployed correctly
            address deterministicAddress = safeFactory.getDeterministicAddress(newSalt);
            assertTrue(safeFactory.isEtherFiSafe(deterministicAddress));
        }

        vm.stopPrank();
    }

    function test_isEtherFiSafe_returnsFalse_forNonSafeAddress() public {
        // Check random address is not recognized as a safe
        address randomAddress = makeAddr("randomAddress");
        assertFalse(safeFactory.isEtherFiSafe(randomAddress));
    }

    function test_getDeployedAddresses_succeeds() public {
        vm.startPrank(owner);

        // Deploy multiple safes
        bytes32[] memory salts = new bytes32[](5);
        address[] memory expectedAddresses = new address[](5);

        for (uint256 i = 0; i < 5; i++) {
            salts[i] = keccak256(abi.encodePacked("testSafe", i));
            safeFactory.deployEtherFiSafe(salts[i], owners, modules, moduleSetupData, testThreshold);
            expectedAddresses[i] = safeFactory.getDeterministicAddress(salts[i]);
        }

        // Get a subset of deployed addresses
        address[] memory retrievedAddresses = safeFactory.getDeployedAddresses(1, 3);

        // Verify the retrieved addresses match the expected ones
        assertEq(retrievedAddresses.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(safeFactory.isEtherFiSafe(retrievedAddresses[i]));
        }

        // Get all deployed addresses from start
        address[] memory allAddresses = safeFactory.getDeployedAddresses(0, 10);

        // Should include the initial safe from setUp and the 5 we just deployed
        assertEq(allAddresses.length, 6);

        vm.stopPrank();
    }

    function test_getDeployedAddresses_adjustsCount_whenRequestingTooMany() public {
        vm.startPrank(owner);

        // Deploy 3 new safes
        for (uint256 i = 0; i < 3; i++) {
            bytes32 newSalt = keccak256(abi.encodePacked("adjustCountSafe", i));
            safeFactory.deployEtherFiSafe(newSalt, owners, modules, moduleSetupData, testThreshold);
        }

        // Request more addresses than exist, starting from index 1
        // Total should be 4 (original safe + 3 new ones)
        address[] memory retrievedAddresses = safeFactory.getDeployedAddresses(1, 10);

        // Should only return 3 addresses (4 total - 1 starting index)
        assertEq(retrievedAddresses.length, 3);

        vm.stopPrank();
    }

    function test_getDeployedAddresses_reverts_whenStartIndexIsInvalid() public {
        // Attempt to get addresses with an invalid start index
        vm.expectRevert(EtherFiSafeFactory.InvalidStartIndex.selector);
        safeFactory.getDeployedAddresses(100, 10);
    }

    function test_getDeterministicAddress_returnsSameAddress_forSameSalt() public {
        bytes32 testSalt = keccak256("deterministicTest");

        // Get address before deployment
        address preDeployAddress = safeFactory.getDeterministicAddress(testSalt);

        // Deploy the safe
        vm.startPrank(owner);
        safeFactory.deployEtherFiSafe(testSalt, owners, modules, moduleSetupData, testThreshold);
        vm.stopPrank();

        // Get address after deployment
        address postDeployAddress = safeFactory.getDeterministicAddress(testSalt);

        // Addresses should match
        assertEq(preDeployAddress, postDeployAddress);
        assertTrue(safeFactory.isEtherFiSafe(postDeployAddress));
    }

    function test_deployEtherFiSafe_succeeds_withMinimumOwners() public {
        vm.startPrank(owner);

        // Create minimum owners (1 owner with threshold 1)
        address[] memory minOwners = new address[](1);
        minOwners[0] = owner1;
        bytes32 newSalt = keccak256("minOwnersSafe");

        // Deploy a new safe with minimum owners
        safeFactory.deployEtherFiSafe(newSalt, minOwners, modules, moduleSetupData, 1);

        // Verify the safe was deployed correctly
        address payable deterministicAddress = payable(safeFactory.getDeterministicAddress(newSalt));
        assertTrue(safeFactory.isEtherFiSafe(deterministicAddress));

        // Check if the safe is properly initialized
        EtherFiSafe newSafe = EtherFiSafe(deterministicAddress);
        assertEq(newSafe.getThreshold(), 1);

        address[] memory newSafeOwners = newSafe.getOwners();
        assertEq(newSafeOwners.length, 1);

        vm.stopPrank();
    }

    function test_upgradeBeaconImplementation_succeeds() public {
        vm.startPrank(owner);
        
        address newImplementation = address(new EtherFiSafe(address(dataProvider)));
        // Get the current implementation before upgrade
        address oldImpl = UpgradeableBeacon(safeFactory.beacon()).implementation();
        
        // Verify old implementation is not the same as new implementation
        assertNotEq(oldImpl, newImplementation);
        
        // Check for event emission
        vm.expectEmit(true, true, true, true);
        emit BeaconFactory.BeaconImplemenationUpgraded(oldImpl, newImplementation);
        
        // Upgrade the implementation
        safeFactory.upgradeBeaconImplementation(newImplementation);
        
        // Verify the implementation was updated
        address updatedImpl = UpgradeableBeacon(safeFactory.beacon()).implementation();
        assertEq(updatedImpl, newImplementation);
        
        vm.stopPrank();
    }
    
    function test_upgradeBeaconImplementation_reverts_whenCallerIsNotOwner() public {
        vm.startPrank(notOwner);
        
        address newImplementation = address(new EtherFiSafe(address(dataProvider)));
        // Expect the upgrade to revert because caller is not the owner
        vm.expectRevert(BeaconFactory.OnlyRoleRegistryOwner.selector);
        safeFactory.upgradeBeaconImplementation(newImplementation);
        
        vm.stopPrank();
    }
    
    function test_upgradeBeaconImplementation_reverts_whenNewImplIsZeroAddress() public {
        vm.startPrank(owner);
        
        // Expect the upgrade to revert because new implementation is zero address
        vm.expectRevert(BeaconFactory.InvalidInput.selector);
        safeFactory.upgradeBeaconImplementation(address(0));
        
        vm.stopPrank();
    }
    
    function test_upgradeBeaconImplementation_affectsNewDeployments() public {
        // First upgrade the implementation
        address newImplementation = address(new EtherFiSafe(address(dataProvider)));
        vm.startPrank(owner);
        safeFactory.upgradeBeaconImplementation(newImplementation);
        vm.stopPrank();
        
        // Now deploy a new safe
        vm.startPrank(owner);
        bytes32 newSalt = keccak256("newImplementationSafe");
        
        address[] memory safeOwners = new address[](1);
        safeOwners[0] = owner1;
        
        address[] memory noModules = new address[](0);
        bytes[] memory noModuleSetupData = new bytes[](0);
        
        safeFactory.deployEtherFiSafe(newSalt, safeOwners, noModules, noModuleSetupData, 1);
        vm.stopPrank();
        
        // Get the deployed safe address
        address payable newSafeAddress = payable(safeFactory.getDeterministicAddress(newSalt));
        
        // Verify the safe was deployed with the new implementation
        // This is an indirect test as we can't directly check which implementation a proxy uses
        // but we can verify the safe works as expected
        EtherFiSafe newSafe = EtherFiSafe(newSafeAddress);
        assertTrue(newSafe.isOwner(owner1));
        assertEq(newSafe.getThreshold(), 1);
    }
        
    function test_upgradeBeaconImplementation_maintainsStorage() public {
        // Set up the initial state
        vm.startPrank(owner);

        address newImplementation = address(new EtherFiSafe(address(dataProvider)));
        
        // Deploy a safe with minimum configuration
        bytes32 testSalt = keccak256("storageTestSafe");
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = owner1;
        
        address[] memory noModules = new address[](0);
        bytes[] memory noModuleSetupData = new bytes[](0);
        
        safeFactory.deployEtherFiSafe(testSalt, initialOwners, noModules, noModuleSetupData, 1);
        address payable safeAddress = payable(safeFactory.getDeterministicAddress(testSalt));
        EtherFiSafe testSafe = EtherFiSafe(safeAddress);
        
        // Upgrade the implementation
        safeFactory.upgradeBeaconImplementation(newImplementation);
        
        // Verify the safe still maintains its state
        assertTrue(testSafe.isOwner(owner1));
        assertEq(testSafe.getThreshold(), 1);
        
        vm.stopPrank();
    }

}
