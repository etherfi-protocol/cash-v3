// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAaveV4Hub
 * @notice The slice of the Aave v4 Hub that the AaveV4Lens reads.
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

    /// @notice Returns the current annual drawn (borrow) rate of the asset, in RAY.
    function getAssetDrawnRate(uint256 assetId) external view returns (uint256);

    /// @notice Returns the asset configuration.
    function getAssetConfig(uint256 assetId) external view returns (AssetConfig memory);
}
