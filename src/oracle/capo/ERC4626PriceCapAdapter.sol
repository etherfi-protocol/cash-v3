// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPriceCapAdapter, PriceCapAdapterBase } from "./vendor/PriceCapAdapterBase.sol";

/**
 * @title ERC4626PriceCapAdapter
 * @notice Price capped adapter for an ERC4626 vault share: prices (share / USD) from the vault's own
 *         redemption rate times a (asset / USD) feed, with the rate's growth capped.
 *
 * @author ether.fi
 */
contract ERC4626PriceCapAdapter is PriceCapAdapterBase {
    using Math for uint256;
    using SafeCast for uint256;

    /// @notice The precision `getRatio()` reports in, independent of the vault's asset
    uint8 public constant NORMALISED_RATIO_DECIMALS = 18;

    /// @notice The vault's underlying asset — the asset `BASE_TO_USD_AGGREGATOR` must price
    address public immutable ASSET;
    /// @notice One whole share, 10 ** the vault's share decimals — the amount quoted to previewRedeem
    uint256 public immutable SHARE_UNIT;
    /// @notice One whole asset, 10 ** the asset's decimals — what the raw rate is normalised from
    uint256 public immutable ASSET_UNIT;

    /**
     * @param capAdapterParams parameters to create cap adapter, with `ratioProviderAddress` set to the
     *        ERC4626 vault and `baseAggregatorAddress` to a feed for the vault's underlying asset
     */
    constructor(CapAdapterParams memory capAdapterParams) PriceCapAdapterBase(CapAdapterBaseParams({ aclManager: capAdapterParams.aclManager, baseAggregatorAddress: capAdapterParams.baseAggregatorAddress, ratioProviderAddress: capAdapterParams.ratioProviderAddress, pairDescription: capAdapterParams.pairDescription, ratioDecimals: NORMALISED_RATIO_DECIMALS, minimumSnapshotDelay: capAdapterParams.minimumSnapshotDelay, priceCapParams: capAdapterParams.priceCapParams })) {
        address asset = IERC4626(capAdapterParams.ratioProviderAddress).asset();
        ASSET = asset;
        SHARE_UNIT = 10 ** IERC4626(capAdapterParams.ratioProviderAddress).decimals();
        ASSET_UNIT = 10 ** IERC20Metadata(asset).decimals();
    }

    /// @inheritdoc IPriceCapAdapter
    /// @dev Assets redeemable for one whole share, normalised to `NORMALISED_RATIO_DECIMALS`
    function getRatio() public view override returns (int256) {
        uint256 assets = IERC4626(RATIO_PROVIDER).previewRedeem(SHARE_UNIT);

        return assets.mulDiv(10 ** NORMALISED_RATIO_DECIMALS, ASSET_UNIT).toInt256();
    }
}
