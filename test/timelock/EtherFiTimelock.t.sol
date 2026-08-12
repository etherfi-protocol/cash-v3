// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";

contract EtherFiTimelockTest is Test {
    uint256 public constant TIMELOCK_DELAY = 8 hours;
    bytes32 public constant TEST_ROLE = keccak256("TEST_ROLE");

    EtherFiTimelock timelock;
    RoleRegistry roleRegistry;

    address governanceMultisig = makeAddr("governanceMultisig");
    address alice = makeAddr("alice");
    address dataProvider = makeAddr("dataProvider");

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = governanceMultisig;

        address[] memory executors = new address[](1);
        executors[0] = governanceMultisig;

        timelock = new EtherFiTimelock(TIMELOCK_DELAY, proposers, executors, address(0));

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, governanceMultisig))));

        // Governance hands RoleRegistry ownership to the timelock via solady's two-step
        // handover (STAKE-1674 flow, exercised end-to-end in test_ownershipHandover_*)
        vm.prank(address(timelock));
        roleRegistry.requestOwnershipHandover();
        vm.prank(governanceMultisig);
        roleRegistry.completeOwnershipHandover(address(timelock));
    }

    function test_ownershipHandover_throughScheduledOperation() public {
        // Replay the production flow on a fresh registry: the handover request is itself a
        // timelocked operation, proving the schedule -> execute round-trip before ownership moves
        RoleRegistry fresh = RoleRegistry(address(new UUPSProxy(address(new RoleRegistry(dataProvider)), abi.encodeWithSelector(RoleRegistry.initialize.selector, governanceMultisig))));

        bytes memory request = abi.encodeWithSignature("requestOwnershipHandover()");
        vm.prank(governanceMultisig);
        timelock.schedule(address(fresh), 0, request, bytes32(0), bytes32(0), TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(governanceMultisig);
        timelock.execute(address(fresh), 0, request, bytes32(0), bytes32(0));

        // The safe — still owner — completes the handover
        assertEq(fresh.owner(), governanceMultisig);
        vm.prank(governanceMultisig);
        fresh.completeOwnershipHandover(address(timelock));

        assertEq(fresh.owner(), address(timelock));
    }

    function _scheduleGrantRole(address account) internal returns (bytes memory payload) {
        payload = abi.encodeWithSelector(RoleRegistry.grantRole.selector, TEST_ROLE, account);
        vm.prank(governanceMultisig);
        timelock.schedule(address(roleRegistry), 0, payload, bytes32(0), bytes32(0), TIMELOCK_DELAY);
    }

    function test_constructor_setsDelayAndRoles() public view {
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governanceMultisig));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), governanceMultisig));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), governanceMultisig));

        // No external admin: the timelock administers its own roles
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), governanceMultisig));

        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), alice));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), alice));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), alice));

        assertEq(roleRegistry.owner(), address(timelock));
    }

    function test_ownerAction_executesThroughTimelock_afterDelay() public {
        bytes memory payload = _scheduleGrantRole(alice);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(governanceMultisig);
        timelock.execute(address(roleRegistry), 0, payload, bytes32(0), bytes32(0));

        assertTrue(roleRegistry.hasRole(TEST_ROLE, alice));
    }

    function test_ownerAction_reverts_beforeDelayElapsed() public {
        bytes memory payload = _scheduleGrantRole(alice);
        bytes32 id = timelock.hashOperation(address(roleRegistry), 0, payload, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        timelock.execute(address(roleRegistry), 0, payload, bytes32(0), bytes32(0));
    }

    function test_schedule_reverts_whenNotProposer() public {
        bytes memory payload = abi.encodeWithSelector(RoleRegistry.grantRole.selector, TEST_ROLE, alice);

        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, proposerRole));
        timelock.schedule(address(roleRegistry), 0, payload, bytes32(0), bytes32(0), TIMELOCK_DELAY);
    }

    function test_execute_reverts_whenNotExecutor() public {
        bytes memory payload = _scheduleGrantRole(alice);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, executorRole));
        timelock.execute(address(roleRegistry), 0, payload, bytes32(0), bytes32(0));
    }

    function test_schedule_reverts_whenDelayBelowMinimum() public {
        bytes memory payload = abi.encodeWithSelector(RoleRegistry.grantRole.selector, TEST_ROLE, alice);

        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, TIMELOCK_DELAY - 1, TIMELOCK_DELAY));
        timelock.schedule(address(roleRegistry), 0, payload, bytes32(0), bytes32(0), TIMELOCK_DELAY - 1);
    }

    function test_multisig_cannotBypassTimelock_onceOwnershipTransferred() public {
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSignature("EnumerableRolesUnauthorized()"));
        roleRegistry.grantRole(TEST_ROLE, alice);
    }

    function test_canceller_canCancelScheduledOperation() public {
        bytes memory payload = _scheduleGrantRole(alice);
        bytes32 id = timelock.hashOperation(address(roleRegistry), 0, payload, bytes32(0), bytes32(0));

        vm.prank(governanceMultisig);
        timelock.cancel(id);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        timelock.execute(address(roleRegistry), 0, payload, bytes32(0), bytes32(0));
    }

    function test_updateDelay_onlyThroughTimelockItself() public {
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, governanceMultisig));
        timelock.updateDelay(1 days);

        // Delay changes must themselves be scheduled and wait out the current delay
        bytes memory payload = abi.encodeWithSelector(TimelockController.updateDelay.selector, 3 days);
        vm.prank(governanceMultisig);
        timelock.schedule(address(timelock), 0, payload, bytes32(0), bytes32(0), TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(governanceMultisig);
        timelock.execute(address(timelock), 0, payload, bytes32(0), bytes32(0));

        assertEq(timelock.getMinDelay(), 3 days);
    }
}
