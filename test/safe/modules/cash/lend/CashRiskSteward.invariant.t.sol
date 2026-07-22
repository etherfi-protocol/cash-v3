// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { CashRiskSteward } from "../../../../../../src/aave-v4/CashRiskSteward.sol";
import { IAaveV4Hub } from "../../../../../../src/interfaces/IAaveV4Hub.sol";
import { MockAaveV4Hub, MockAaveV4HubConfigurator } from "./mocks/MockAaveV4Hub.sol";

/**
 * @title CashRiskStewardHandler
 * @notice Drives the steward through random keeper sequences, adversary bypass attempts, an adversarial
 *         cap ratchet, and time warps. The fuzzer picks the actions; the invariant contract checks the
 *         band holds. `keeperAdjustInBand` asserts per-call that a valid move actually lands, so the
 *         campaign is structurally non-vacuous (the fuzzer cannot "pass" by only ever reverting).
 */
contract CashRiskStewardHandler is Test {
    CashRiskSteward public steward;
    MockAaveV4Hub public hub;
    MockAaveV4HubConfigurator public configurator;
    uint256 public immutable assetId;
    address public immutable spoke;
    address public immutable keeper;
    address public immutable attacker;

    uint256 internal constant FLOOR = 1_000_000;
    uint256 internal constant CEILING = 90_000_000;
    uint256 internal constant MAX_STEP = 10_000_000;

    constructor(CashRiskSteward steward_, MockAaveV4Hub hub_, MockAaveV4HubConfigurator configurator_, uint256 assetId_, address spoke_, address keeper_, address attacker_) {
        steward = steward_;
        hub = hub_;
        configurator = configurator_;
        assetId = assetId_;
        spoke = spoke_;
        keeper = keeper_;
        attacker = attacker_;
    }

    /// @dev Guaranteed-success keeper path: reads the live cap, picks a target provably inside both the
    ///      band and the step window, warps past cooldown, adjusts. MUST succeed and land exactly —
    ///      asserted per-call, which is what makes the campaign non-vacuous.
    function keeperAdjustInBand(uint256 seed) external {
        uint256 cur = steward.currentDrawCap();
        uint256 lo = cur > MAX_STEP ? cur - MAX_STEP : 0;
        if (lo < FLOOR) lo = FLOOR;
        uint256 hi = cur + MAX_STEP;
        if (hi > CEILING) hi = CEILING;
        uint256 target = bound(seed, lo, hi);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        steward.adjustDrawCap(target);

        assertEq(steward.currentDrawCap(), target, "in-band move did not land on target");
    }

    /// @dev Unconstrained target (straddles the band) to exercise the rejection paths.
    function keeperAdjust(uint256 target) external {
        target = bound(target, 0, 120_000_000);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        try steward.adjustDrawCap(target) { } catch { }
    }

    /// @dev Adversarial ratchet: a compromised keeper's real play — push the cap UP by the max step
    ///      every cooldown, climbing toward the ceiling. Each step is individually step-valid, so only
    ///      the CEILING check can stop the climb. This is what makes the ceiling invariant bite.
    function keeperRatchetUp() external {
        uint256 target = steward.currentDrawCap() + MAX_STEP;
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        try steward.adjustDrawCap(target) { } catch { }
    }

    /// @dev Attacker calls the configurator directly (must always revert: no AccessManager role).
    function attackerBypass(uint256 target) external {
        vm.prank(attacker);
        try configurator.updateSpokeDrawCap(address(hub), assetId, spoke, target) { } catch { }
    }

    /// @dev Advance time so cooldown can clear across the sequence.
    function warp(uint256 dt) external {
        dt = bound(dt, 0, 3 hours);
        vm.warp(block.timestamp + dt);
    }
}

/**
 * @title CashRiskStewardInvariant
 * @notice No reachable sequence of keeper actions, adversary bypass attempts, cap ratchets, or time
 *         warps can push the live drawCap outside [FLOOR, CEILING] or up to the uncapped sentinel.
 */
contract CashRiskStewardInvariant is Test {
    MockAaveV4Hub internal hub;
    MockAaveV4HubConfigurator internal configurator;
    CashRiskSteward internal steward;
    CashRiskStewardHandler internal handler;

    address internal governance = makeAddr("governance");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant ASSET_ID = 3;
    address internal spoke = makeAddr("cashSpoke");

    uint256 internal constant FLOOR = 1_000_000;
    uint256 internal constant CEILING = 90_000_000;
    uint256 internal constant MAX_STEP = 10_000_000;
    uint256 internal constant COOLDOWN = 1 hours;
    uint256 internal constant INIT_CAP = 50_000_000;

    function setUp() public {
        vm.warp(1_700_000_000);

        hub = new MockAaveV4Hub();
        configurator = new MockAaveV4HubConfigurator(hub);
        hub.setConfigurator(address(configurator));
        hub.seedConfig(ASSET_ID, spoke, IAaveV4Hub.SpokeConfig({ addCap: type(uint40).max, drawCap: uint40(INIT_CAP), riskPremiumThreshold: 0, active: true, halted: false }));
        steward = new CashRiskSteward(address(configurator), address(hub), ASSET_ID, spoke, governance, keeper, FLOOR, CEILING, MAX_STEP, COOLDOWN);
        configurator.grantDrawCapRole(address(steward)); // only the steward holds the role

        handler = new CashRiskStewardHandler(steward, hub, configurator, ASSET_ID, spoke, keeper, attacker);
        targetContract(address(handler));
    }

    /// @notice Core invariant: the live drawCap always stays inside [FLOOR, CEILING] and never reaches
    ///         the uncapped sentinel, no matter the action sequence.
    function invariant_DrawCapStaysInBand() public view {
        uint256 cap = steward.currentDrawCap();
        assertGe(cap, FLOOR, "cap fell below floor");
        assertLe(cap, CEILING, "cap rose above ceiling");
        assertLt(cap, uint256(type(uint40).max), "cap reached the uncapped sentinel");
    }

    /// @notice The spoke must never be uncapped.
    function invariant_NeverUncapped() public view {
        assertTrue(steward.currentDrawCap() != uint256(type(uint40).max), "spoke got uncapped");
    }
}
