// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RevokeAdmin } from "../../src/role-registry/RevokeAdmin.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract RevokeFastTest is Test {
    RoleRegistry public roleRegistry;
    RevokeAdmin public revokeAdmin;

    address public owner = makeAddr("owner");
    address public adminMultisig = makeAddr("adminMultisig");
    address public stranger = makeAddr("stranger");
    address public opsKey = makeAddr("opsKey");

    bytes32 constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    event RevokeAdminSet(address oldRevokeAdmin, address newRevokeAdmin);
    event RoleRevokedFast(bytes32 indexed role, address indexed account);

    function setUp() public {
        vm.startPrank(owner);

        address impl = address(new RoleRegistry(makeAddr("dataProvider")));
        roleRegistry = RoleRegistry(address(new UUPSProxy(impl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        revokeAdmin = new RevokeAdmin(address(roleRegistry));
        roleRegistry.setRevokeAdmin(address(revokeAdmin));

        roleRegistry.grantRole(roleRegistry.ADMIN_ROLE(), adminMultisig);
        vm.stopPrank();
    }

    // setRevokeAdmin

    function test_setRevokeAdmin_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        roleRegistry.setRevokeAdmin(stranger);
    }

    function test_setRevokeAdmin_setsAndEmits() public {
        address newRevokeAdmin = makeAddr("newRevokeAdmin");
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RevokeAdminSet(address(revokeAdmin), newRevokeAdmin);
        roleRegistry.setRevokeAdmin(newRevokeAdmin);
        assertEq(roleRegistry.revokeAdmin(), newRevokeAdmin);
    }

    // revokeFast on the registry

    function test_revokeFast_reverts_whenCallerNotRevokeAdmin() public {
        vm.prank(adminMultisig);
        vm.expectRevert(RoleRegistry.OnlyRevokeAdmin.selector);
        roleRegistry.revokeFast(ETHER_FI_WALLET_ROLE, opsKey);
    }

    function test_revokeFast_reverts_forProtectedRoles() public {
        bytes32 adminRole = roleRegistry.ADMIN_ROLE();
        bytes32 adminTimelockRole = roleRegistry.ADMIN_TIMELOCK_ROLE();

        vm.startPrank(address(revokeAdmin));
        vm.expectRevert(RoleRegistry.InvalidRoleToRevoke.selector);
        roleRegistry.revokeFast(adminRole, adminMultisig);
        vm.expectRevert(RoleRegistry.InvalidRoleToRevoke.selector);
        roleRegistry.revokeFast(adminTimelockRole, adminMultisig);
        vm.stopPrank();
    }

    function test_revokeFast_revokesInstantly() public {
        vm.prank(owner);
        roleRegistry.grantRole(ETHER_FI_WALLET_ROLE, opsKey);
        assertTrue(roleRegistry.hasRole(ETHER_FI_WALLET_ROLE, opsKey));

        vm.prank(address(revokeAdmin));
        vm.expectEmit(true, true, false, true);
        emit RoleRevokedFast(ETHER_FI_WALLET_ROLE, opsKey);
        roleRegistry.revokeFast(ETHER_FI_WALLET_ROLE, opsKey);

        assertFalse(roleRegistry.hasRole(ETHER_FI_WALLET_ROLE, opsKey));
    }

    // RevokeAdmin wrapper

    function test_revokeAdmin_namedRevoke_worksForMultisig() public {
        vm.prank(owner);
        roleRegistry.grantRole(ETHER_FI_WALLET_ROLE, opsKey);

        vm.prank(adminMultisig);
        revokeAdmin.revokeEtherFiWalletRole(opsKey);

        assertFalse(roleRegistry.hasRole(ETHER_FI_WALLET_ROLE, opsKey));
    }

    function test_revokeAdmin_genericRevoke_worksForMultisig() public {
        bytes32 role = keccak256("TOP_UP_ROLE");
        vm.prank(owner);
        roleRegistry.grantRole(role, opsKey);

        vm.prank(adminMultisig);
        revokeAdmin.revokeRoleFast(role, opsKey);

        assertFalse(roleRegistry.hasRole(role, opsKey));
    }

    function test_revokeAdmin_reverts_whenCallerNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(RoleRegistry.OnlyAdmin.selector);
        revokeAdmin.revokeEtherFiWalletRole(opsKey);
    }

    function test_revokeAdmin_cannotRevokeProtectedRoles() public {
        bytes32 adminRole = roleRegistry.ADMIN_ROLE();
        bytes32 adminTimelockRole = roleRegistry.ADMIN_TIMELOCK_ROLE();

        vm.startPrank(adminMultisig);
        vm.expectRevert(RoleRegistry.InvalidRoleToRevoke.selector);
        revokeAdmin.revokeRoleFast(adminRole, adminMultisig);
        vm.expectRevert(RoleRegistry.InvalidRoleToRevoke.selector);
        revokeAdmin.revokeRoleFast(adminTimelockRole, adminMultisig);
        vm.stopPrank();
    }

    function test_revokeFast_disabled_whenRevokeAdminUnset() public {
        vm.prank(owner);
        roleRegistry.setRevokeAdmin(address(0));

        vm.prank(address(revokeAdmin));
        vm.expectRevert(RoleRegistry.OnlyRevokeAdmin.selector);
        roleRegistry.revokeFast(ETHER_FI_WALLET_ROLE, opsKey);
    }
}
