// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IAaveV4Hub } from "../interfaces/IAaveV4Hub.sol";

/// @dev The single Aave v4 HubConfigurator call the steward drives. `updateSpokeDrawCap` reads the
///      spoke's current SpokeConfig, overwrites only `drawCap`, and writes it back through the Hub;
///      it is `restricted` on the real HubConfigurator, so the steward must hold the AccessManager
///      role scoped to this selector. Verified against aave-v4 (submodule commit cdacec50):
///      src/hub/HubConfigurator.sol:222, src/hub/interfaces/IHubConfigurator.sol:169.
interface IAaveV4HubConfigurator {
    function updateSpokeDrawCap(address hub, uint256 assetId, address spoke, uint256 drawCap) external;
}

/**
 * @title CashRiskSteward
 * @notice Bounds-enforcing wrapper for the ether.fi whitelabel instance's per-spoke borrow cap
 *         (`drawCap`). It lets a low-trust keeper (an EOA or 1-of-N) tune the Cash spoke's borrow
 *         cap to track live supply — keeping utilization stable and deposits withdrawable — while
 *         governance keeps the cap boxed inside an on-chain band the keeper can never leave.
 * @dev WHY THIS EXISTS. Aave v4's AccessManager gates WHO may call `updateSpokeDrawCap` and with what
 *      delay, but places NO bound on the drawCap VALUE: `Hub._updateSpokeConfig` does a raw
 *      `spokeData.drawCap = config.drawCap` with no ceiling/floor check (aave-v4 @ cdacec50,
 *      Hub.sol:710). So a key granted that selector directly could set drawCap to 0 (freeze all Cash
 *      borrows) or to `MAX_ALLOWED_SPOKE_CAP` (uncap the spoke -> utilization to 100% -> borrow rate
 *      spikes and LP withdrawals block). Granting the AccessManager role to THIS contract instead of
 *      the keeper closes that gap: every keeper move is checked against a governance ceiling, floor,
 *      per-update step, and cooldown, so a full keeper-key compromise is confined to an availability-
 *      neutral band [floor, ceiling] and can never uncap the spoke.
 *
 *      TRUST MODEL.
 *      - Governance = the `Ownable2Step` owner (a multisig, ideally behind a timelock). Sets the
 *        bounds, rotates the keeper, pauses, and has an incident-response setter that skips the
 *        cooldown/step throttle but is STILL boxed by [floor, ceiling].
 *      - Keeper = a hot EOA / 1-of-N. May only move drawCap within the live bounds, throttled by the
 *        cooldown and per-update step. Safe to run hot precisely because the lever is availability-
 *        only: the steward cannot touch collateral factors, liquidation params, or user funds.
 *
 *      The steward drives exactly ONE lever (`drawCap`) on ONE (hub, assetId, spoke), fixed at deploy.
 * @author ether.fi
 */
contract CashRiskSteward is Ownable2Step {
    /// @notice The Aave v4 HubConfigurator the steward calls (holds the AccessManager drawCap role)
    IAaveV4HubConfigurator public immutable hubConfigurator;
    /// @notice The Hub whose per-spoke cap is being tuned
    address public immutable hub;
    /// @notice The asset (e.g. USDC) whose borrow cap is being tuned
    uint256 public immutable assetId;
    /// @notice The Cash spoke whose `drawCap` is being tuned
    address public immutable spoke;
    /// @notice Aave's "uncapped" sentinel; the steward must never let a cap reach it
    uint40 public immutable maxAllowedSpokeCap;

    /// @notice Hard upper bound on `drawCap` (whole tokens). Kept strictly below `maxAllowedSpokeCap`
    ///         so the spoke can never be widened to uncapped.
    uint256 public maxDrawCapCeiling;
    /// @notice Hard lower bound on `drawCap` (whole tokens). A value > 0 prevents a borrow-freeze grief.
    uint256 public minDrawCapFloor;
    /// @notice Max change in `drawCap` a single keeper update may make (whole tokens).
    uint256 public maxStep;
    /// @notice Minimum seconds between keeper updates.
    uint256 public cooldown;

    /// @notice The hot key allowed to tune the cap within bounds.
    address public keeper;
    /// @notice Timestamp of the last cap update (keeper or governance path).
    uint256 public lastUpdateTime;
    /// @notice When true, keeper updates are blocked (governance path still works).
    bool public paused;

    event DrawCapAdjusted(uint256 oldCap, uint256 newCap, address indexed by);
    event BoundsUpdated(uint256 floor, uint256 ceiling, uint256 maxStep, uint256 cooldown);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event PausedSet(bool paused);

    error NotKeeper();
    error ZeroAddress();
    error Paused();
    error CooldownActive(uint256 readyAt);
    error BelowFloor(uint256 floor);
    error AboveCeiling(uint256 ceiling);
    error StepTooLarge(uint256 maxStep, uint256 requested);
    error InvalidBounds();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(address hubConfigurator_, address hub_, uint256 assetId_, address spoke_, address governance_, address keeper_, uint256 floor_, uint256 ceiling_, uint256 maxStep_, uint256 cooldown_) Ownable(governance_) {
        if (hubConfigurator_ == address(0) || hub_ == address(0) || spoke_ == address(0) || keeper_ == address(0)) {
            revert ZeroAddress();
        }

        hubConfigurator = IAaveV4HubConfigurator(hubConfigurator_);
        hub = hub_;
        assetId = assetId_;
        spoke = spoke_;
        maxAllowedSpokeCap = IAaveV4Hub(hub_).MAX_ALLOWED_SPOKE_CAP();

        keeper = keeper_;
        _setBounds(floor_, ceiling_, maxStep_, cooldown_);
    }

    /// @notice Move the spoke's `drawCap` to `newDrawCap`, subject to all bounds. The keeper's only
    ///         mutating entrypoint. Reads the current cap live from the Hub as the single source of
    ///         truth; a revert leaves on-chain state untouched.
    function adjustDrawCap(uint256 newDrawCap) external onlyKeeper {
        if (paused) revert Paused();

        uint256 readyAt = lastUpdateTime + cooldown;
        if (block.timestamp < readyAt) revert CooldownActive(readyAt);

        uint256 currentCap = currentDrawCap();

        // Band: ceiling < maxAllowedSpokeCap guarantees the spoke can never be uncapped; floor > 0
        // guarantees borrows can never be frozen to zero.
        if (newDrawCap < minDrawCapFloor) revert BelowFloor(minDrawCapFloor);
        if (newDrawCap > maxDrawCapCeiling) revert AboveCeiling(maxDrawCapCeiling);

        // Per-update step bounds the blast radius of a single rogue or buggy keeper call.
        uint256 delta = newDrawCap > currentCap ? newDrawCap - currentCap : currentCap - newDrawCap;
        if (delta > maxStep) revert StepTooLarge(maxStep, delta);

        lastUpdateTime = block.timestamp;
        hubConfigurator.updateSpokeDrawCap(hub, assetId, spoke, newDrawCap);

        emit DrawCapAdjusted(currentCap, newDrawCap, msg.sender);
    }

    /// @notice The live `drawCap` for this spoke as stored on the Hub.
    function currentDrawCap() public view returns (uint256) {
        return uint256(IAaveV4Hub(hub).getSpokeConfig(assetId, spoke).drawCap);
    }

    /// @notice Seconds until the keeper may next update (0 if ready now).
    function timeUntilReady() external view returns (uint256) {
        uint256 readyAt = lastUpdateTime + cooldown;
        return block.timestamp >= readyAt ? 0 : readyAt - block.timestamp;
    }

    /// @notice Governance: update the bounds the keeper operates within.
    function setBounds(uint256 floor_, uint256 ceiling_, uint256 maxStep_, uint256 cooldown_) external onlyOwner {
        _setBounds(floor_, ceiling_, maxStep_, cooldown_);
    }

    /// @notice Governance: rotate the keeper key.
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice Governance: pause/unpause keeper updates.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Governance incident-response setter: snap the cap immediately, skipping the cooldown and
    ///         per-update step throttle. Still boxed by [floor, ceiling] — governance cannot uncap
    ///         either, so the band remains a hard invariant across every entrypoint.
    function governanceSetDrawCap(uint256 newDrawCap) external onlyOwner {
        if (newDrawCap < minDrawCapFloor) revert BelowFloor(minDrawCapFloor);
        if (newDrawCap > maxDrawCapCeiling) revert AboveCeiling(maxDrawCapCeiling);
        uint256 currentCap = currentDrawCap();
        lastUpdateTime = block.timestamp;
        hubConfigurator.updateSpokeDrawCap(hub, assetId, spoke, newDrawCap);
        emit DrawCapAdjusted(currentCap, newDrawCap, msg.sender);
    }

    /// @dev floor <= ceiling, ceiling strictly below Aave's uncapped sentinel (so the steward can never
    ///      widen the spoke to unlimited), and maxStep > 0 (else the keeper is bricked).
    function _setBounds(uint256 floor_, uint256 ceiling_, uint256 maxStep_, uint256 cooldown_) internal {
        if (floor_ > ceiling_) revert InvalidBounds();
        if (ceiling_ >= uint256(maxAllowedSpokeCap)) revert InvalidBounds();
        if (maxStep_ == 0) revert InvalidBounds();

        minDrawCapFloor = floor_;
        maxDrawCapCeiling = ceiling_;
        maxStep = maxStep_;
        cooldown = cooldown_;

        emit BoundsUpdated(floor_, ceiling_, maxStep_, cooldown_);
    }
}
