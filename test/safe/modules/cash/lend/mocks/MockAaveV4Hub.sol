// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAaveV4Hub } from "../../../../../../src/interfaces/IAaveV4Hub.sol";

/// @dev Faithful mock of the drawCap slice of the Aave v4 Hub. Reproduces the behaviour the steward
///      defends against: the cap write path applies NO ceiling/floor validation (aave-v4 @ cdacec50,
///      Hub.sol:710). The write is gated to `hubConfigurator` only, mirroring the real AccessManager
///      `restricted` gate on HubConfigurator. Read-only lens methods are stubbed (unused by the steward).
contract MockAaveV4Hub is IAaveV4Hub {
    uint40 public constant MAX_CAP = type(uint40).max;

    address public hubConfigurator;
    mapping(uint256 => mapping(address => SpokeConfig)) internal _cfg;

    error OnlyConfigurator();

    function setConfigurator(address configurator) external {
        hubConfigurator = configurator;
    }

    function MAX_ALLOWED_SPOKE_CAP() external pure returns (uint40) {
        return MAX_CAP;
    }

    function getSpokeConfig(uint256 assetId, address spoke) external view returns (SpokeConfig memory) {
        return _cfg[assetId][spoke];
    }

    /// @dev Seed initial config for tests (bypasses the gate, as protocol deployment would).
    function seedConfig(uint256 assetId, address spoke, SpokeConfig calldata config) external {
        _cfg[assetId][spoke] = config;
    }

    /// @dev The ONLY drawCap write path. NO ceiling/floor validation — exactly like Aave v4. Callable
    ///      only by the configurator, which is itself role-gated to the steward.
    function writeDrawCap(uint256 assetId, address spoke, uint40 drawCap) external {
        if (msg.sender != hubConfigurator) revert OnlyConfigurator();
        _cfg[assetId][spoke].drawCap = drawCap;
    }

    // --- unused lens surface (present to satisfy IAaveV4Hub) ---
    function getAssetDrawnRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function getAssetDrawnIndex(uint256) external pure returns (uint256) {
        return 0;
    }

    function previewRemoveByShares(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function previewRemoveByAssets(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function previewDrawByShares(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function getAssetConfig(uint256) external pure returns (AssetConfig memory) {
        return AssetConfig(address(0), 0, address(0), address(0));
    }

    function getAssetLiquidity(uint256) external pure returns (uint256) {
        return 0;
    }

    function getSpokeTotalOwed(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function getSpokeDeficitRay(uint256, address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Faithful mock of Aave v4's HubConfigurator.updateSpokeDrawCap: read current SpokeConfig,
///      overwrite ONLY drawCap, write back (aave-v4 @ cdacec50, HubConfigurator.sol:222) — with NO
///      value bound. The `restricted` modifier is modelled by an explicit AccessManager-style role
///      check: only addresses granted the drawCap role (the steward) may call it.
contract MockAaveV4HubConfigurator {
    MockAaveV4Hub public immutable hub;
    mapping(address => bool) public hasDrawCapRole;

    error Restricted();

    constructor(MockAaveV4Hub hub_) {
        hub = hub_;
    }

    /// @dev Mirrors AccessManager granting the updateSpokeDrawCap selector to an address.
    function grantDrawCapRole(address account) external {
        hasDrawCapRole[account] = true;
    }

    function updateSpokeDrawCap(address, uint256 assetId, address spoke, uint256 drawCap) external {
        if (!hasDrawCapRole[msg.sender]) revert Restricted();
        // No bound check here or downstream — the honest reproduction of the Aave gap.
        hub.writeDrawCap(assetId, spoke, uint40(drawCap));
    }
}
