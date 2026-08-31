// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract RevokeFastTest is Test {
    RoleRegistry public roleRegistry;

    address public owner = makeAddr("owner");
    address public adminMultisig = makeAddr("adminMultisig");
    address public stranger = makeAddr("stranger");
    address public opsKey = makeAddr("opsKey");

    bytes32 constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    event RoleRevokedFast(bytes32 indexed role, address indexed account);

    function setUp() public {
        vm.startPrank(owner);

        address impl = address(new RoleRegistry(makeAddr("dataProvider")));
        roleRegistry = RoleRegistry(address(new UUPSProxy(impl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        roleRegistry.grantRole(roleRegistry.ADMIN_ROLE(), adminMultisig);
        vm.stopPrank();
    }

    function test_revokeFast_revokesInstantly() public {
        vm.prank(owner);
        roleRegistry.grantRole(ETHER_FI_WALLET_ROLE, opsKey);
        assertTrue(roleRegistry.hasRole(ETHER_FI_WALLET_ROLE, opsKey));

        vm.prank(adminMultisig);
        vm.expectEmit(true, true, false, true);
        emit RoleRevokedFast(ETHER_FI_WALLET_ROLE, opsKey);
        roleRegistry.revokeFast(ETHER_FI_WALLET_ROLE, opsKey);

        assertFalse(roleRegistry.hasRole(ETHER_FI_WALLET_ROLE, opsKey));
    }

    function test_revokeFast_reverts_whenCallerNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(RoleRegistry.OnlyAdmin.selector);
        roleRegistry.revokeFast(ETHER_FI_WALLET_ROLE, opsKey);
    }

    function test_revokeFast_reverts_forOwnerWithoutAdminRole() public {
        // even the registry owner cannot use the fast path without holding ADMIN_ROLE
        vm.prank(owner);
        vm.expectRevert(RoleRegistry.OnlyAdmin.selector);
        roleRegistry.revokeFast(ETHER_FI_WALLET_ROLE, opsKey);
    }

    function test_revokeFast_reverts_forProtectedRoles() public {
        bytes32 adminRole = roleRegistry.ADMIN_ROLE();
        bytes32 adminTimelockRole = roleRegistry.ADMIN_TIMELOCK_ROLE();

        vm.startPrank(adminMultisig);
        vm.expectRevert(RoleRegistry.InvalidRoleToRevoke.selector);
        roleRegistry.revokeFast(adminRole, adminMultisig);
        vm.expectRevert(RoleRegistry.InvalidRoleToRevoke.selector);
        roleRegistry.revokeFast(adminTimelockRole, adminMultisig);
        vm.stopPrank();
    }

    function test_revokeFast_worksForAnyOperationalRole() public {
        bytes32[] memory roles = new bytes32[](4);
        roles[0] = keccak256("TOP_UP_ROLE");
        roles[1] = keccak256("PAUSER");
        roles[2] = keccak256("UNPAUSER");
        roles[3] = keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE");

        for (uint256 i = 0; i < roles.length; i++) {
            vm.prank(owner);
            roleRegistry.grantRole(roles[i], opsKey);

            vm.prank(adminMultisig);
            roleRegistry.revokeFast(roles[i], opsKey);

            assertFalse(roleRegistry.hasRole(roles[i], opsKey));
        }
    }
}
