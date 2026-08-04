// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { PausableUntil } from "../../src/utils/PausableUntil.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";

contract PausableUntilHarness is UpgradeableProxy {
    constructor() {
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    function gated() external view whenNotPaused returns (bool) {
        return true;
    }

    function gatedUntilOnly() external view whenNotPausedUntil returns (bool) {
        return true;
    }
}

contract PausableUntilTest is Test {
    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PausableUntil")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant PAUSABLE_UNTIL_STORAGE_SLOT = 0x297e298dc05105929d8ca10b807082979fcd5337ac991fc8f17dce28e407b000;

    RoleRegistry public roleRegistry;
    PausableUntilHarness public harness;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public secondGuardian = makeAddr("secondGuardian");
    address public governance = makeAddr("governance");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public alice = makeAddr("alice");

    event PausedUntil(uint256 pausedUntil);
    event UnpausedUntil();
    event PauseUntilDurationSet(uint256 pauseUntilDuration);

    function setUp() public {
        // Avoid the degenerate case where lastPauseTimestamp == 0 interacts with small
        // foundry default timestamps in the cooldown math
        vm.warp(1_700_000_000);

        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry(makeAddr("dataProvider")));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);
        roleRegistry.grantRole(keccak256("GUARDIAN_ROLE"), guardian);
        roleRegistry.grantRole(keccak256("GUARDIAN_ROLE"), secondGuardian);
        roleRegistry.grantRole(keccak256("GOVERNANCE_ROLE"), governance);

        address harnessImpl = address(new PausableUntilHarness());
        harness = PausableUntilHarness(address(new UUPSProxy(harnessImpl, abi.encodeWithSelector(PausableUntilHarness.initialize.selector, address(roleRegistry)))));

        vm.stopPrank();
    }

    // ---- Constants & storage ----

    function test_constants() public view {
        assertEq(harness.MIN_PAUSE_DURATION(), 8 hours);
        assertEq(harness.MAX_PAUSE_DURATION(), 30 days);
        assertEq(harness.PAUSER_UNTIL_COOLDOWN(), 7 days);
        assertEq(harness.GUARDIAN_ROLE(), keccak256("GUARDIAN_ROLE"));
    }

    function test_storageSlot_matchesErc7201Formula() public pure {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("etherfi.storage.PausableUntil")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(PAUSABLE_UNTIL_STORAGE_SLOT, expected);
    }

    function test_storageSlot_holdsPausedUntil() public {
        vm.prank(guardian);
        harness.pauseUntil();

        assertEq(uint256(vm.load(address(harness), PAUSABLE_UNTIL_STORAGE_SLOT)), harness.pausedUntil());
        assertEq(harness.pausedUntil(), block.timestamp + harness.MIN_PAUSE_DURATION());
    }

    // ---- setPauseUntilDuration ----

    function test_setPauseUntilDuration_setsStateAndEmits() public {
        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit PauseUntilDurationSet(1 days);
        harness.setPauseUntilDuration(1 days);

        assertEq(harness.pauseUntilDuration(), 1 days);
    }

    function test_setPauseUntilDuration_acceptsBoundaries() public {
        vm.startPrank(governance);
        harness.setPauseUntilDuration(harness.MIN_PAUSE_DURATION());
        assertEq(harness.pauseUntilDuration(), harness.MIN_PAUSE_DURATION());

        harness.setPauseUntilDuration(harness.MAX_PAUSE_DURATION());
        assertEq(harness.pauseUntilDuration(), harness.MAX_PAUSE_DURATION());
        vm.stopPrank();
    }

    function test_setPauseUntilDuration_revertsOutOfBounds() public {
        vm.startPrank(governance);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.setPauseUntilDuration(8 hours - 1);

        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.setPauseUntilDuration(30 days + 1);

        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.setPauseUntilDuration(0);
        vm.stopPrank();
    }

    function test_setPauseUntilDuration_revertsWhenNotGovernance() public {
        vm.prank(guardian);
        vm.expectRevert(UpgradeableProxy.OnlyGovernanceMultisig.selector);
        harness.setPauseUntilDuration(1 days);

        vm.prank(pauser);
        vm.expectRevert(UpgradeableProxy.OnlyGovernanceMultisig.selector);
        harness.setPauseUntilDuration(1 days);
    }

    function testFuzz_setPauseUntilDuration(uint256 duration) public {
        vm.prank(governance);
        if (duration < 8 hours || duration > 30 days) {
            vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
            harness.setPauseUntilDuration(duration);
        } else {
            harness.setPauseUntilDuration(duration);
            assertEq(harness.pauseUntilDuration(), duration);
        }
    }

    // ---- pauseUntil ----

    function test_pauseUntil_setsStateAndEmits() public {
        vm.prank(governance);
        harness.setPauseUntilDuration(1 days);

        vm.prank(guardian);
        vm.expectEmit(true, true, true, true);
        emit PausedUntil(block.timestamp + 1 days);
        harness.pauseUntil();

        assertEq(harness.pausedUntil(), block.timestamp + 1 days);
        assertEq(harness.lastPauseTimestamp(guardian), block.timestamp);
        assertTrue(harness.isPaused());
    }

    function test_pauseUntil_fallsBackToMinDurationWhenUnset() public {
        assertEq(harness.pauseUntilDuration(), 0);

        vm.prank(guardian);
        harness.pauseUntil();

        assertEq(harness.pausedUntil(), block.timestamp + harness.MIN_PAUSE_DURATION());
    }

    function test_pauseUntil_blocksGatedFunction() public {
        assertTrue(harness.gated());
        assertTrue(harness.gatedUntilOnly());

        vm.prank(guardian);
        harness.pauseUntil();

        uint256 pausedUntil = harness.pausedUntil();
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntil));
        harness.gated();

        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntil));
        harness.gatedUntilOnly();
    }

    function test_pauseUntil_revertsWhenNotGuardian() public {
        vm.prank(alice);
        vm.expectRevert(PausableUntil.OnlyGuardian.selector);
        harness.pauseUntil();

        // PAUSER can pause indefinitely but cannot trip the timed pause
        vm.prank(pauser);
        vm.expectRevert(PausableUntil.OnlyGuardian.selector);
        harness.pauseUntil();
    }

    function test_pauseUntil_revertsIfAlreadyPaused() public {
        vm.prank(guardian);
        harness.pauseUntil();

        uint256 pausedUntil = harness.pausedUntil();
        vm.prank(secondGuardian);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntil));
        harness.pauseUntil();
    }

    function test_pauseUntil_expiresAutomatically() public {
        vm.prank(guardian);
        harness.pauseUntil();

        uint256 pausedUntil = harness.pausedUntil();

        // Still paused at the exact boundary
        vm.warp(pausedUntil);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntil));
        harness.gated();
        assertTrue(harness.isPaused());

        // Unblocked one second later, with no unpause transaction
        vm.warp(pausedUntil + 1);
        assertTrue(harness.gated());
        assertFalse(harness.isPaused());
    }

    function test_pauseUntil_revertsWhilePauserInCooldown() public {
        vm.prank(guardian);
        harness.pauseUntil();

        // Past expiry but within the cooldown window
        vm.warp(harness.pausedUntil() + 1);
        vm.prank(guardian);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        harness.pauseUntil();
    }

    function test_pauseUntil_allowsRepauseAfterExpiryPlusCooldown() public {
        vm.prank(guardian);
        harness.pauseUntil();

        uint256 duration = harness.MIN_PAUSE_DURATION();
        uint256 pausedAt = block.timestamp;

        // Strict boundary: lastPause + duration + cooldown must be <= now
        vm.warp(pausedAt + duration + harness.PAUSER_UNTIL_COOLDOWN() - 1);
        vm.prank(guardian);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        harness.pauseUntil();

        vm.warp(pausedAt + duration + harness.PAUSER_UNTIL_COOLDOWN());
        vm.prank(guardian);
        harness.pauseUntil();
        assertEq(harness.pausedUntil(), block.timestamp + duration);
    }

    function test_pauseUntil_cooldownsAreIndependentPerGuardian() public {
        vm.prank(guardian);
        harness.pauseUntil();

        // After expiry the first guardian is in cooldown, but the second is not
        vm.warp(harness.pausedUntil() + 1);
        vm.prank(secondGuardian);
        harness.pauseUntil();

        assertEq(harness.pausedUntil(), block.timestamp + harness.MIN_PAUSE_DURATION());
        assertEq(harness.lastPauseTimestamp(secondGuardian), block.timestamp);
    }

    // ---- unpauseUntil ----

    function test_unpauseUntil_clearsStateAndEmits() public {
        vm.prank(guardian);
        harness.pauseUntil();

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit UnpausedUntil();
        harness.unpauseUntil();

        assertEq(harness.pausedUntil(), 0);
        assertFalse(harness.isPaused());
        assertTrue(harness.gated());
    }

    function test_unpauseUntil_revertsWhenNotPaused() public {
        vm.prank(governance);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        harness.unpauseUntil();
    }

    function test_unpauseUntil_revertsAfterExpiry() public {
        vm.prank(guardian);
        harness.pauseUntil();

        vm.warp(harness.pausedUntil() + 1);
        vm.prank(governance);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        harness.unpauseUntil();
    }

    function test_unpauseUntil_revertsWhenNotGovernance() public {
        vm.prank(guardian);
        harness.pauseUntil();

        vm.prank(guardian);
        vm.expectRevert(UpgradeableProxy.OnlyGovernanceMultisig.selector);
        harness.unpauseUntil();

        vm.prank(unpauser);
        vm.expectRevert(UpgradeableProxy.OnlyGovernanceMultisig.selector);
        harness.unpauseUntil();
    }

    function test_unpauseUntil_doesNotClearPauserCooldown() public {
        uint256 pausedAt = block.timestamp;
        vm.prank(guardian);
        harness.pauseUntil();

        vm.prank(governance);
        harness.unpauseUntil();

        // Early unpause does not refund the cooldown
        vm.prank(guardian);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        harness.pauseUntil();

        // But another guardian can pause immediately
        vm.prank(secondGuardian);
        harness.pauseUntil();
        vm.prank(governance);
        harness.unpauseUntil();

        // Original guardian frees up only after duration + cooldown from its own pause
        vm.warp(pausedAt + harness.MIN_PAUSE_DURATION() + harness.PAUSER_UNTIL_COOLDOWN());
        vm.prank(guardian);
        harness.pauseUntil();
    }

    // ---- Interaction with the indefinite pause ----

    function test_indefinitePause_unaffectedByMixin() public {
        vm.prank(pauser);
        harness.pause();
        assertTrue(harness.paused());
        assertTrue(harness.isPaused());

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        harness.gated();

        // whenNotPausedUntil ignores the indefinite pause
        assertTrue(harness.gatedUntilOnly());

        vm.prank(unpauser);
        harness.unpause();
        assertTrue(harness.gated());
    }

    function test_pauseUntil_allowedWhileIndefinitelyPaused() public {
        vm.prank(pauser);
        harness.pause();

        vm.prank(guardian);
        harness.pauseUntil();

        // Lifting the timed pause keeps the indefinite pause in force
        vm.prank(governance);
        harness.unpauseUntil();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        harness.gated();
    }

    function test_pause_revertsWhileTimedPauseActive() public {
        // Documented quirk: OZ _pause() runs under whenNotPaused, which now also enforces
        // the timed pause — governance must unpauseUntil() before an indefinite pause()
        vm.prank(guardian);
        harness.pauseUntil();

        uint256 pausedUntil = harness.pausedUntil();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntil));
        harness.pause();

        vm.prank(governance);
        harness.unpauseUntil();
        vm.prank(pauser);
        harness.pause();
        assertTrue(harness.paused());
    }

    // ---- Fuzz ----

    function testFuzz_gated_revertsWhilePausedAndPassesAfterExpiry(uint256 duration, uint256 jitter) public {
        duration = bound(duration, 8 hours, 30 days);
        jitter = bound(jitter, 0, 365 days);

        vm.prank(governance);
        harness.setPauseUntilDuration(duration);

        uint256 pausedAt = block.timestamp;
        vm.prank(guardian);
        harness.pauseUntil();

        vm.warp(pausedAt + jitter);
        if (jitter <= duration) {
            vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedAt + duration));
            harness.gated();
        } else {
            assertTrue(harness.gated());
        }
    }

    function testFuzz_cooldown_enforcesMinInterval(uint256 duration, uint256 jitter) public {
        duration = bound(duration, 8 hours, 30 days);
        jitter = bound(jitter, 0, duration + 7 days - 1);

        vm.prank(governance);
        harness.setPauseUntilDuration(duration);

        uint256 pausedAt = block.timestamp;
        vm.prank(guardian);
        harness.pauseUntil();

        vm.warp(pausedAt + jitter);
        vm.prank(guardian);
        if (jitter <= duration) {
            vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedAt + duration));
        } else {
            vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        }
        harness.pauseUntil();

        vm.warp(pausedAt + duration + 7 days);
        vm.prank(guardian);
        harness.pauseUntil();
    }
}
