// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAaveV4Hub
 * @notice The slice of the Aave v4 Hub that ether.fi reads: asset rate/config for the AaveV4Lens, and a
 *         spoke's borrow cap and usage for the LendGateway.
 * @dev Caps are per-spoke and enforced only in the Hub (the Spoke's own checks do not know about them), so a
 *      borrow can pass every Spoke check and still revert here with DrawCapExceeded. Cap values are whole
 *      tokens (not scaled by decimals); the Hub multiplies by 10**decimals at check time. A cap equal to
 *      MAX_ALLOWED_SPOKE_CAP means uncapped. The Hub address and assetId come from IAaveV4Spoke.getReserve.
 * @author ether.fi
 */
interface IAaveV4Hub {
    /// @notice Asset configuration. ABI-mirrored: `liquidityFee` is in BPS.
    struct AssetConfig {
        address feeReceiver;
        uint16 liquidityFee;
        address irStrategy;
        address reinvestmentController;
    }

    /// @notice Per-spoke config for one asset. `addCap`/`drawCap` are whole-token supply/borrow caps.
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    /// @notice Returns the current annual drawn (borrow) rate of the asset, in RAY.
    function getAssetDrawnRate(uint256 assetId) external view returns (uint256);

    /// @notice Returns the current drawn index of the asset, in RAY.
    function getAssetDrawnIndex(uint256 assetId) external view returns (uint256);

    /// @notice Converts supplied shares to removable assets, rounding down.
    function previewRemoveByShares(uint256 assetId, uint256 shares) external view returns (uint256);

    /// @notice Converts removable assets to the supplied shares they burn, rounding up.
    function previewRemoveByAssets(uint256 assetId, uint256 assets) external view returns (uint256);

    /// @notice Converts drawn shares to borrowable assets, rounding down.
    function previewDrawByShares(uint256 assetId, uint256 shares) external view returns (uint256);

    /// @notice Returns the asset configuration.
    function getAssetConfig(uint256 assetId) external view returns (AssetConfig memory);

    /// @notice The spoke's config for `assetId` (incl. `addCap`, `drawCap`, `active`, `halted`).
    function getSpokeConfig(uint256 assetId, address spoke) external view returns (SpokeConfig memory);

    /// @notice The Hub's available underlying liquidity for `assetId`, shared by every Spoke.
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);

    /// @notice The spoke's current borrow usage for `assetId` (drawn + premium), in asset units.
    function getSpokeTotalOwed(uint256 assetId, address spoke) external view returns (uint256);

    /// @notice The spoke's reported deficit for `assetId`, in asset units scaled by RAY.
    function getSpokeDeficitRay(uint256 assetId, address spoke) external view returns (uint256);

    /// @notice The cap sentinel meaning "uncapped": a cap equal to this imposes no limit.
    function MAX_ALLOWED_SPOKE_CAP() external view returns (uint40);
}
