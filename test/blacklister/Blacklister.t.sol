// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { Blacklister } from "../../src/blacklister/Blacklister.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract BlacklisterTest is Test {
    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.Blacklister")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant BLACKLISTER_STORAGE_SLOT = 0x9ea2b95533369649149a4112dbf03a9ec872da99b01b6ea9b13a361bcd248100;

    RoleRegistry public roleRegistry;
    Blacklister public blacklister;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public governance = makeAddr("governance");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    event UserBlacklisted(address indexed user);
    event UserUnblacklisted(address indexed user);
    event UserBlacklistedUntil(address indexed user, uint256 until);

    function setUp() public {
        vm.warp(1_700_000_000);

        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry(makeAddr("dataProvider")));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        roleRegistry.grantRole(keccak256("GUARDIAN_ROLE"), guardian);
        roleRegistry.grantRole(keccak256("GOVERNANCE_ROLE"), governance);

        address blacklisterImpl = address(new Blacklister(address(roleRegistry)));
        blacklister = Blacklister(address(new UUPSProxy(blacklisterImpl, abi.encodeWithSelector(Blacklister.initialize.selector))));

        vm.stopPrank();
    }

    // ---- Constants & storage ----

    function test_constants() public view {
        assertEq(blacklister.BLACKLIST_DURATION(), 3 days);
        assertEq(blacklister.GUARDIAN_ROLE(), keccak256("GUARDIAN_ROLE"));
        assertEq(blacklister.GOVERNANCE_ROLE(), keccak256("GOVERNANCE_ROLE"));
        assertEq(address(blacklister.roleRegistry()), address(roleRegistry));
    }

    function test_storageSlot_matchesErc7201Formula() public pure {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("etherfi.storage.Blacklister")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(BLACKLISTER_STORAGE_SLOT, expected);
    }

    function test_storageSlot_holdsBlacklistMapping() public {
        vm.prank(guardian);
        blacklister.blacklistUserUntil(alice);

        bytes32 mappingSlot = keccak256(abi.encode(alice, BLACKLISTER_STORAGE_SLOT));
        assertEq(uint256(vm.load(address(blacklister), mappingSlot)), blacklister.blacklistedUntil(alice));
    }

    // ---- blacklistUserUntil (guardian path) ----

    function test_blacklistUserUntil_setsFixedWindowAndEmits() public {
        vm.prank(guardian);
        vm.expectEmit(true, true, true, true);
        emit UserBlacklistedUntil(alice, block.timestamp + 3 days);
        blacklister.blacklistUserUntil(alice);

        assertEq(blacklister.blacklistedUntil(alice), block.timestamp + 3 days);
        assertTrue(blacklister.isBlacklisted(alice));
    }

    function test_blacklistUserUntil_revertsForZeroAddress() public {
        vm.prank(guardian);
        vm.expectRevert(Blacklister.InvalidUser.selector);
        blacklister.blacklistUserUntil(address(0));
    }

    function test_blacklistUserUntil_revertsWhenNotGuardian() public {
        vm.prank(alice);
        vm.expectRevert(Blacklister.OnlyGuardian.selector);
        blacklister.blacklistUserUntil(bob);

        // Governance holds the multisig paths but not the guardian path — disjoint, not hierarchical
        vm.prank(governance);
        vm.expectRevert(Blacklister.OnlyGuardian.selector);
        blacklister.blacklistUserUntil(bob);
    }

    function test_blacklistUserUntil_revertsWhileStillActive() public {
        vm.prank(guardian);
        blacklister.blacklistUserUntil(alice);

        // A guardian cannot chain 3-day windows into an indefinite freeze
        vm.warp(block.timestamp + 3 days - 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Blacklister.UserAlreadyBlacklisted.selector, alice));
        blacklister.blacklistUserUntil(alice);
    }

    function test_blacklistUserUntil_canReblacklistAfterExpiry() public {
        vm.prank(guardian);
        blacklister.blacklistUserUntil(alice);

        uint256 until = blacklister.blacklistedUntil(alice);
        vm.warp(until);

        vm.prank(guardian);
        blacklister.blacklistUserUntil(alice);
        assertEq(blacklister.blacklistedUntil(alice), until + 3 days);
    }

    // ---- nonBlacklisted boundary ----

    function test_nonBlacklisted_strictBoundary() public {
        vm.prank(guardian);
        blacklister.blacklistUserUntil(alice);

        uint256 until = blacklister.blacklistedUntil(alice);

        // One second before expiry: gate closed
        vm.warp(until - 1);
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, alice));
        blacklister.nonBlacklisted(alice);
        assertTrue(blacklister.isBlacklisted(alice));

        // At exactly `until` (strict > check): gate open, no transaction needed
        vm.warp(until);
        blacklister.nonBlacklisted(alice);
        assertFalse(blacklister.isBlacklisted(alice));
    }

    function test_nonBlacklisted_passesForCleanAddress() public view {
        blacklister.nonBlacklisted(alice);
        assertFalse(blacklister.isBlacklisted(alice));
        assertEq(blacklister.blacklistedUntil(alice), 0);
    }

    // ---- setBlacklistUntil (governance path) ----

    function test_setBlacklistUntil_usesDurationSemantics() public {
        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit UserBlacklistedUntil(alice, block.timestamp + 7 days);
        blacklister.setBlacklistUntil(alice, 7 days);

        assertEq(blacklister.blacklistedUntil(alice), block.timestamp + 7 days);
    }

    function test_setBlacklistUntil_zeroDurationIsImmediatelyOpen() public {
        vm.prank(governance);
        blacklister.setBlacklistUntil(alice, 0);

        // until == block.timestamp and the gate is strict >, so alice is not blacklisted
        blacklister.nonBlacklisted(alice);
        assertFalse(blacklister.isBlacklisted(alice));
    }

    function test_setBlacklistUntil_overwritesExistingBlacklist() public {
        vm.prank(governance);
        blacklister.blacklistUser(alice);
        assertEq(blacklister.blacklistedUntil(alice), type(uint256).max);

        // Overwrite, not extend: governance can shorten an indefinite blacklist to a window
        vm.prank(governance);
        blacklister.setBlacklistUntil(alice, 1 days);
        assertEq(blacklister.blacklistedUntil(alice), block.timestamp + 1 days);
    }

    function test_setBlacklistUntil_revertsForZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(Blacklister.InvalidUser.selector);
        blacklister.setBlacklistUntil(address(0), 1 days);
    }

    function test_setBlacklistUntil_revertsWhenNotGovernance() public {
        vm.prank(guardian);
        vm.expectRevert(Blacklister.OnlyGovernanceMultisig.selector);
        blacklister.setBlacklistUntil(alice, 1 days);
    }

    // ---- blacklistUser (indefinite governance path) ----

    function test_blacklistUser_neverExpires() public {
        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit UserBlacklisted(alice);
        blacklister.blacklistUser(alice);

        vm.warp(block.timestamp + 365 days * 100);
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, alice));
        blacklister.nonBlacklisted(alice);
        assertTrue(blacklister.isBlacklisted(alice));
    }

    function test_blacklistUser_revertsForZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(Blacklister.InvalidUser.selector);
        blacklister.blacklistUser(address(0));
    }

    function test_blacklistUser_revertsWhenNotGovernance() public {
        vm.prank(guardian);
        vm.expectRevert(Blacklister.OnlyGovernanceMultisig.selector);
        blacklister.blacklistUser(alice);
    }

    // ---- unblacklistUser ----

    function test_unblacklistUser_clearsTimedBlacklist() public {
        vm.prank(guardian);
        blacklister.blacklistUserUntil(alice);

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit UserUnblacklisted(alice);
        blacklister.unblacklistUser(alice);

        assertEq(blacklister.blacklistedUntil(alice), 0);
        blacklister.nonBlacklisted(alice);
    }

    function test_unblacklistUser_clearsIndefiniteBlacklist() public {
        vm.prank(governance);
        blacklister.blacklistUser(alice);

        vm.prank(governance);
        blacklister.unblacklistUser(alice);
        assertFalse(blacklister.isBlacklisted(alice));
    }

    function test_unblacklistUser_revertsWhenNotGovernance() public {
        vm.prank(governance);
        blacklister.blacklistUser(alice);

        vm.prank(guardian);
        vm.expectRevert(Blacklister.OnlyGovernanceMultisig.selector);
        blacklister.unblacklistUser(alice);
    }

    // ---- Independence between users ----

    function test_blacklist_isPerUser() public {
        vm.prank(guardian);
        blacklister.blacklistUserUntil(alice);

        blacklister.nonBlacklisted(bob);

        // Guardian can blacklist a second address while the first is active
        vm.prank(guardian);
        blacklister.blacklistUserUntil(bob);
        assertTrue(blacklister.isBlacklisted(bob));
    }

    // ---- Upgrade auth ----

    function test_upgrade_onlyRoleRegistryOwner() public {
        address newImpl = address(new Blacklister(address(roleRegistry)));

        vm.prank(guardian);
        vm.expectRevert(RoleRegistry.OnlyUpgrader.selector);
        blacklister.upgradeToAndCall(newImpl, "");

        vm.prank(owner);
        blacklister.upgradeToAndCall(newImpl, "");
    }

    // ---- Fuzz ----

    function testFuzz_setBlacklistUntil_expiryBoundary(uint256 duration, uint256 jitter) public {
        duration = bound(duration, 1, 3650 days);
        jitter = bound(jitter, 0, 7300 days);

        uint256 t0 = block.timestamp;
        vm.prank(governance);
        blacklister.setBlacklistUntil(alice, duration);

        vm.warp(t0 + jitter);
        if (jitter < duration) {
            vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, alice));
            blacklister.nonBlacklisted(alice);
            assertTrue(blacklister.isBlacklisted(alice));
        } else {
            blacklister.nonBlacklisted(alice);
            assertFalse(blacklister.isBlacklisted(alice));
        }
    }
}
