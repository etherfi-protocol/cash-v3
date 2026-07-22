// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { CashRiskSteward } from "../../../../../../src/aave-v4/CashRiskSteward.sol";
import { IAaveV4Hub } from "../../../../../../src/interfaces/IAaveV4Hub.sol";
import { MockAaveV4Hub, MockAaveV4HubConfigurator } from "./mocks/MockAaveV4Hub.sol";

/**
 * @title CashRiskStewardBase
 * @notice Shared setup: a mocked Aave v4 Hub + HubConfigurator, a seeded Cash spoke drawCap, and a
 *         steward that (as in production) is the SOLE holder of the AccessManager drawCap role.
 */
contract CashRiskStewardBase is Test {
    MockAaveV4Hub internal hub;
    MockAaveV4HubConfigurator internal configurator;
    CashRiskSteward internal steward;

    address internal governance = makeAddr("governance");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant ASSET_ID = 3;
    address internal spoke = makeAddr("cashSpoke");

    // whole-token bounds (USDC), matching Aave's whole-asset cap units
    uint256 internal constant FLOOR = 1_000_000; //  1M USDC minimum borrow cap (no freeze)
    uint256 internal constant CEILING = 90_000_000; // 90M USDC hard ceiling (no uncap)
    uint256 internal constant MAX_STEP = 10_000_000; // 10M per update
    uint256 internal constant COOLDOWN = 1 hours;
    uint256 internal constant INIT_CAP = 50_000_000; // 50M starting cap

    function setUp() public virtual {
        vm.warp(1_700_000_000); // realistic epoch: block.timestamp >> cooldown, so the first call is ready

        hub = new MockAaveV4Hub();
        configurator = new MockAaveV4HubConfigurator(hub);
        hub.setConfigurator(address(configurator));

        hub.seedConfig(ASSET_ID, spoke, IAaveV4Hub.SpokeConfig({ addCap: type(uint40).max, drawCap: uint40(INIT_CAP), riskPremiumThreshold: 0, active: true, halted: false }));

        steward = new CashRiskSteward(address(configurator), address(hub), ASSET_ID, spoke, governance, keeper, FLOOR, CEILING, MAX_STEP, COOLDOWN);

        // AccessManager: the drawCap role goes to the STEWARD, never the keeper.
        configurator.grantDrawCapRole(address(steward));
    }

    function _reseed(uint40 cap) internal {
        hub.seedConfig(ASSET_ID, spoke, IAaveV4Hub.SpokeConfig({ addCap: type(uint40).max, drawCap: cap, riskPremiumThreshold: 0, active: true, halted: false }));
    }
}

contract CashRiskStewardTest is CashRiskStewardBase {
    // --- the Aave v4 gap this contract closes ---

    /// @notice Proves the gap: a raw role-holder can uncap the spoke to unlimited (the attack the
    ///         steward exists to prevent).
    function test_RawRoleHolder_CanUncapToUnlimited() public {
        configurator.grantDrawCapRole(attacker);
        vm.prank(attacker);
        configurator.updateSpokeDrawCap(address(hub), ASSET_ID, spoke, type(uint40).max);
        assertEq(steward.currentDrawCap(), uint256(type(uint40).max));
    }

    /// @notice Proves the grief: a raw role-holder can zero the cap and freeze all borrows.
    function test_RawRoleHolder_CanFreezeBorrows() public {
        configurator.grantDrawCapRole(attacker);
        vm.prank(attacker);
        configurator.updateSpokeDrawCap(address(hub), ASSET_ID, spoke, 0);
        assertEq(steward.currentDrawCap(), 0);
    }

    // --- the fix: the steward is the only role-holder; the keeper is boxed ---

    function test_KeeperCannotCallConfiguratorDirectly() public {
        vm.prank(keeper);
        vm.expectRevert(MockAaveV4HubConfigurator.Restricted.selector);
        configurator.updateSpokeDrawCap(address(hub), ASSET_ID, spoke, 80_000_000);
    }

    function test_Keeper_CanAdjustWithinBounds() public {
        vm.prank(keeper);
        steward.adjustDrawCap(45_000_000);
        assertEq(steward.currentDrawCap(), 45_000_000);
    }

    function test_Keeper_CannotExceedCeiling() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashRiskSteward.AboveCeiling.selector, CEILING));
        steward.adjustDrawCap(CEILING + 1);
    }

    function test_Keeper_CannotUncap() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashRiskSteward.AboveCeiling.selector, CEILING));
        steward.adjustDrawCap(type(uint40).max);
    }

    function test_Keeper_CannotGoBelowFloor() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashRiskSteward.BelowFloor.selector, FLOOR));
        steward.adjustDrawCap(FLOOR - 1);
    }

    function test_Keeper_CannotZeroFreeze() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashRiskSteward.BelowFloor.selector, FLOOR));
        steward.adjustDrawCap(0);
    }

    function test_Keeper_StepLimited() public {
        // current = 50M, step limit 10M -> 65M is a 15M jump -> revert
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashRiskSteward.StepTooLarge.selector, MAX_STEP, 15_000_000));
        steward.adjustDrawCap(65_000_000);
    }

    function test_Cooldown_Enforced() public {
        vm.prank(keeper);
        steward.adjustDrawCap(55_000_000);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CashRiskSteward.CooldownActive.selector, block.timestamp + COOLDOWN));
        steward.adjustDrawCap(52_000_000);

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(keeper);
        steward.adjustDrawCap(52_000_000);
        assertEq(steward.currentDrawCap(), 52_000_000);
    }

    function test_OnlyKeeper() public {
        vm.prank(attacker);
        vm.expectRevert(CashRiskSteward.NotKeeper.selector);
        steward.adjustDrawCap(45_000_000);
    }

    function test_OnlyGovernance_SetBounds() public {
        vm.prank(attacker);
        vm.expectRevert();
        steward.setBounds(FLOOR, CEILING, MAX_STEP, COOLDOWN);
    }

    function test_Governance_RejectsCeilingAtOrAboveMax() public {
        vm.prank(governance);
        vm.expectRevert(CashRiskSteward.InvalidBounds.selector);
        steward.setBounds(FLOOR, uint256(type(uint40).max), MAX_STEP, COOLDOWN);
    }

    function test_Governance_EmergencyBypassesCooldownButNotBounds() public {
        vm.prank(keeper);
        steward.adjustDrawCap(55_000_000); // arms cooldown

        // governance snaps the cap to the floor immediately (incident response), skipping cooldown/step
        vm.prank(governance);
        steward.governanceSetDrawCap(FLOOR);
        assertEq(steward.currentDrawCap(), FLOOR);

        // but governance still cannot uncap
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(CashRiskSteward.AboveCeiling.selector, CEILING));
        steward.governanceSetDrawCap(CEILING + 1);
    }

    function test_Pause_BlocksKeeper() public {
        vm.prank(governance);
        steward.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(CashRiskSteward.Paused.selector);
        steward.adjustDrawCap(45_000_000);
    }

    function test_TwoStepGovernanceTransfer() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        steward.transferOwnership(newGov);
        assertEq(steward.owner(), governance, "not transferred until accepted");
        vm.prank(newGov);
        steward.acceptOwnership();
        assertEq(steward.owner(), newGov, "transferred after accept");
    }

    function test_SetKeeper_RotatesHotKey() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(governance);
        steward.setKeeper(newKeeper);

        vm.prank(keeper);
        vm.expectRevert(CashRiskSteward.NotKeeper.selector);
        steward.adjustDrawCap(45_000_000);

        vm.prank(newKeeper);
        steward.adjustDrawCap(45_000_000);
        assertEq(steward.currentDrawCap(), 45_000_000);
    }

    // --- fuzz: any target, any starting cap, always ends in-band ---

    /// @notice For ANY fuzzed target and ANY fuzzed starting cap, the resulting on-chain cap is either
    ///         unchanged (the call reverted) or inside [FLOOR, CEILING] and never the uncapped sentinel.
    function testFuzz_KeeperAdjust_AlwaysInBand(uint256 target, uint40 startCap) public {
        startCap = uint40(bound(startCap, FLOOR, CEILING));
        _reseed(startCap);

        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(keeper);
        try steward.adjustDrawCap(target) {
            uint256 cap = steward.currentDrawCap();
            assertGe(cap, FLOOR, "below floor after success");
            assertLe(cap, CEILING, "above ceiling after success");
            assertLt(cap, uint256(type(uint40).max), "reached uncapped sentinel after success");
            assertEq(cap, target, "success but cap != target");
        } catch {
            assertEq(steward.currentDrawCap(), startCap, "revert must not change state");
        }
    }
}
