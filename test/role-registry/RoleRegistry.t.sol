// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IEtherFiDataProvider } from "../../src/interfaces/IEtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract RoleRegistryTest is Test {
    RoleRegistry public roleRegistry;
    address public dataProviderMock;

    address public owner = makeAddr("owner");
    address public admin = makeAddr("admin");
    address public nonAdmin = makeAddr("nonAdmin");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public safe = makeAddr("safe");
    address public safeAdmin = makeAddr("safeAdmin");
    address public nonSafeAdmin = makeAddr("nonSafeAdmin");

    error EnumerableRolesUnauthorized();
    error Unauthorized();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RoleGranted(address indexed account, uint256 indexed role);
    event RoleRevoked(address indexed account, uint256 indexed role);

    function setUp() public {
        // Create mock data provider
        dataProviderMock = makeAddr("dataProvider");

        vm.startPrank(owner);

        // Deploy role registry
        address roleRegistryImpl = address(new RoleRegistry(dataProviderMock));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        // Set up roles
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        // Set up mock for EtherFiDataProvider
        vm.mockCall(dataProviderMock, abi.encodeWithSelector(IEtherFiDataProvider.onlyEtherFiSafe.selector, safe), abi.encode());

        // Reverts for non-safe addresses
        vm.mockCallRevert(dataProviderMock, abi.encodeWithSelector(IEtherFiDataProvider.onlyEtherFiSafe.selector, nonAdmin), abi.encodeWithSelector(EtherFiDataProvider.OnlyEtherFiSafe.selector));

        vm.stopPrank();
    }

    // Initialization Tests

    function test_initialize_setsOwner() public view {
        assertEq(roleRegistry.owner(), owner);
    }

    function test_initialize_reverts_whenCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        roleRegistry.initialize(owner);
    }

    // getSafeAdminRole Tests

    function test_getSafeAdminRole_returnsUniqueRoleForEachSafe() public {
        address safe1 = makeAddr("safe1");
        address safe2 = makeAddr("safe2");

        bytes32 role1 = roleRegistry.getSafeAdminRole(safe1);
        bytes32 role2 = roleRegistry.getSafeAdminRole(safe2);

        assertTrue(role1 != role2, "Roles should be unique for different safes");
        assertTrue(role1 == keccak256(abi.encode(roleRegistry.SAFE_ADMIN_ROLE_TYPE(), safe1)), "Role should be correctly computed");
    }

    function test_getSafeAdminRole_reverts_withZeroAddress() public {
        vm.expectRevert(RoleRegistry.InvalidInput.selector);
        roleRegistry.getSafeAdminRole(address(0));
    }

    // configureSafeAdmins Tests

    function test_configureSafeAdmins_addsSafeAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = safeAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);

        assertTrue(roleRegistry.isSafeAdmin(safe, safeAdmin), "Account should have safe admin role");
    }

    function test_configureSafeAdmins_removesSafeAdmin() public {
        // First add the admin
        address[] memory accounts = new address[](1);
        accounts[0] = safeAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);

        // Now remove the admin
        shouldAdd[0] = false;

        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);

        assertFalse(roleRegistry.isSafeAdmin(safe, safeAdmin), "Account should not have safe admin role");
    }

    function test_configureSafeAdmins_reverts_whenCalledByNonSafe() public {
        address[] memory accounts = new address[](1);
        accounts[0] = safeAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.expectRevert(EtherFiDataProvider.OnlyEtherFiSafe.selector);
        vm.prank(nonAdmin);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);
    }

    function test_configureSafeAdmins_reverts_whenEmptyAccounts() public {
        address[] memory accounts = new address[](0);
        bool[] memory shouldAdd = new bool[](0);

        vm.expectRevert(RoleRegistry.InvalidInput.selector);
        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);
    }

    function test_configureSafeAdmins_reverts_whenArrayLengthMismatch() public {
        address[] memory accounts = new address[](2);
        accounts[0] = safeAdmin;
        accounts[1] = nonSafeAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.expectRevert(RoleRegistry.ArrayLengthMismatch.selector);
        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);
    }

    function test_configureSafeAdmins_reverts_whenZeroAddressAccount() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(0);

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.expectRevert(RoleRegistry.InvalidInput.selector);
        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);
    }

    // onlySafeAdmin Tests

    function test_onlySafeAdmin_doesNotRevert_forSafeAdmin() public {
        // First add the admin
        address[] memory accounts = new address[](1);
        accounts[0] = safeAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);

        // Check that onlySafeAdmin doesn't revert
        roleRegistry.onlySafeAdmin(safe, safeAdmin);
    }

    function test_onlySafeAdmin_reverts_forNonSafeAdmin() public {
        vm.expectRevert(RoleRegistry.OnlySafeAdmin.selector);
        roleRegistry.onlySafeAdmin(safe, nonSafeAdmin);
    }

    // isSafeAdmin Tests

    function test_isSafeAdmin_returnsCorrectStatus() public {
        // First add the admin
        address[] memory accounts = new address[](1);
        accounts[0] = safeAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);

        assertTrue(roleRegistry.isSafeAdmin(safe, safeAdmin), "Should return true for safe admin");
        assertFalse(roleRegistry.isSafeAdmin(safe, nonSafeAdmin), "Should return false for non-safe admin");
    }

    // getSafeAdmins Tests

    function test_getSafeAdmins_returnsAllAdmins() public {
        // Add multiple admins
        address[] memory accounts = new address[](2);
        accounts[0] = safeAdmin;
        accounts[1] = admin;

        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = true;
        shouldAdd[1] = true;

        vm.prank(safe);
        roleRegistry.configureSafeAdmins(accounts, shouldAdd);

        address[] memory admins = roleRegistry.getSafeAdmins(safe);

        assertEq(admins.length, 2, "Should return correct number of admins");
        assertTrue((admins[0] == safeAdmin && admins[1] == admin) || (admins[0] == admin && admins[1] == safeAdmin), "Should return all added admins");
    }

    // checkRoles Tests

    function test_checkRoles_doesNotRevert_whenAccountHasAnyRole() public view {
        bytes32[] memory roles = new bytes32[](2);
        roles[0] = roleRegistry.PAUSER();
        roles[1] = roleRegistry.UNPAUSER();

        bytes memory encodedRoles = abi.encode(roles);

        // Should not revert for account with PAUSER role
        roleRegistry.checkRoles(pauser, encodedRoles);
    }

    function test_checkRoles_reverts_whenAccountHasNoRoles() public {
        bytes32[] memory roles = new bytes32[](2);
        roles[0] = roleRegistry.PAUSER();
        roles[1] = roleRegistry.UNPAUSER();

        bytes memory encodedRoles = abi.encode(roles);

        // Should revert for account with no roles
        vm.expectRevert(EnumerableRolesUnauthorized.selector);
        roleRegistry.checkRoles(nonAdmin, encodedRoles);
    }

    // hasRole Tests

    function test_hasRole_returnsCorrectStatus() public view {
        assertTrue(roleRegistry.hasRole(roleRegistry.PAUSER(), pauser), "Should return true for account with role");
        assertFalse(roleRegistry.hasRole(roleRegistry.PAUSER(), nonAdmin), "Should return false for account without role");
    }

    // grantRole Tests

    function test_grantRole_addsRole() public {
        vm.prank(owner);
        roleRegistry.grantRole(keccak256("TEST_ROLE"), admin);

        assertTrue(roleRegistry.hasRole(keccak256("TEST_ROLE"), admin), "Account should have the granted role");
    }

    function test_grantRole_reverts_whenCalledByNonOwner() public {
        vm.expectRevert(EnumerableRolesUnauthorized.selector);
        vm.prank(nonAdmin);
        roleRegistry.grantRole(keccak256("TEST_ROLE"), admin);
    }

    // revokeRole Tests

    function test_revokeRole_removesRole() public {
        bytes32 testRole = keccak256("TEST_ROLE");

        // First grant the role
        vm.prank(owner);
        roleRegistry.grantRole(testRole, admin);

        // Then revoke it
        vm.prank(owner);
        roleRegistry.revokeRole(testRole, admin);

        assertFalse(roleRegistry.hasRole(testRole, admin), "Account should not have the revoked role");
    }

    function test_revokeRole_reverts_whenCalledByNonOwner() public {
        bytes32 pauserRole = roleRegistry.PAUSER();

        vm.expectRevert(EnumerableRolesUnauthorized.selector);
        vm.prank(nonAdmin);
        roleRegistry.revokeRole(pauserRole, pauser);
    }

    // roleHolders Tests

    function test_roleHolders_returnsCorrectAccounts() public view {
        address[] memory holders = roleRegistry.roleHolders(roleRegistry.PAUSER());

        assertEq(holders.length, 1, "Should return correct number of role holders");
        assertEq(holders[0], pauser, "Should return the correct role holder");
    }

    // onlyUpgrader Tests

    function test_onlyUpgrader_doesNotRevert_forOwner() public view {
        roleRegistry.onlyUpgrader(owner);
    }

    function test_onlyUpgrader_reverts_forNonOwner() public {
        vm.expectRevert(RoleRegistry.OnlyUpgrader.selector);
        roleRegistry.onlyUpgrader(nonAdmin);
    }

    // onlyPauser Tests

    function test_onlyPauser_doesNotRevert_forPauser() public view {
        roleRegistry.onlyPauser(pauser);
    }

    function test_onlyPauser_reverts_forNonPauser() public {
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
        roleRegistry.onlyPauser(nonAdmin);
    }

    // onlyUnpauser Tests

    function test_onlyUnpauser_doesNotRevert_forUnpauser() public view {
        roleRegistry.onlyUnpauser(unpauser);
    }

    function test_onlyUnpauser_reverts_forNonUnpauser() public {
        vm.expectRevert(RoleRegistry.OnlyUnpauser.selector);
        roleRegistry.onlyUnpauser(nonAdmin);
    }

    // _authorizeUpgrade Tests (via proxy call)

    function test_upgradeProxyCalls_revert_whenNotOwner() public {
        address newImpl = address(new RoleRegistry(dataProviderMock));

        vm.prank(nonAdmin);
        vm.expectRevert(Unauthorized.selector);
        roleRegistry.upgradeToAndCall(newImpl, "");
    }

    function test_upgradeProxyCalls_succeed_whenOwner() public {
        address newImpl = address(new RoleRegistry(dataProviderMock));

        vm.prank(owner);
        roleRegistry.upgradeToAndCall(newImpl, "");
    }
}
