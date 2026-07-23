// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAaveV4Hub } from "../../interfaces/IAaveV4Hub.sol";
import { IAaveV4Oracle } from "../../interfaces/IAaveV4Oracle.sol";
import { IAaveV4Spoke } from "../../interfaces/IAaveV4Spoke.sol";

/**
 * @title LendCapacityLib
 * @notice The LendGateway's Aave-priced capacity math: rebuilds Aave's own health-factor inputs and turns
 *         them into quotes that always pass Aave's own checks.
 * @dev Deployed once and linked into the LendGateway, so this logic does not count against its EIP-170
 *      runtime code-size limit. Storage-free: every input is read from the Spoke, so functions take the
 *      spoke and the resolved reserve id as parameters, and the gateway keeps the asset registry lookups
 *      and the health-factor floor resolution.
 * @author ether.fi
 */
library LendCapacityLib {
    /// @notice Converts collateral weighted by BPS into Aave Value units scaled by RAY, then applies a WAD health factor
    uint256 internal constant WEIGHTED_COLLATERAL_TO_DEBT_RAY = 1e41;
    /// @notice Aave's RAY scale for debt share accounting
    uint256 internal constant RAY = 1e27;

    struct BorrowCapacityData {
        uint256 weightedCollateralValueBps;
        uint256 totalDebtValueRay;
        uint256 targetPrice;
        uint256 targetDrawnIndex;
        uint256 targetDrawnShares;
    }

    /**
     * @notice Rebuilds Aave's own health-factor inputs (Spoke.getUserAccountData) and runs the formula backwards:
     *         HF = weightedCollateral * 1e41 / debt >= floor gives a max debt Value, and the room left under it
     *         converts to target-token debt shares, then to asset units. Every step rounds down, so a borrow of
     *         the quoted amount always passes Aave's own check. Liquidity and caps are separate (borrowLiquidity).
     * @param spoke The Aave Spoke holding the position
     * @param safe The Safe whose position backs the borrow
     * @param targetReserveId The reserve of the asset to borrow
     * @param floor The health-factor floor to hold, in WAD (1e18 is Aave's raw executable bound)
     * @return The maximum additional borrow in asset units
     */
    function borrowCapacity(IAaveV4Spoke spoke, address safe, uint256 targetReserveId, uint256 floor) external view returns (uint256) {
        // Health factor is a whole-position number and the Safe can hold positions outside the gateway
        // registry, so sum collateral and debt across every Spoke reserve, priced by Aave's oracle.
        (uint256[] memory reserveIds, uint256[] memory prices) = _allReservesAndPrices(spoke);
        BorrowCapacityData memory data = _borrowCapacityData(spoke, safe, targetReserveId, reserveIds, prices);

        // Invert HF >= floor into the max debt Value the position may carry (1e41 = Aave's bpsToWad * RAY)
        uint256 maxDebtValueRay = Math.mulDiv(data.weightedCollateralValueBps, WEIGHTED_COLLATERAL_TO_DEBT_RAY, floor);
        if (data.totalDebtValueRay >= maxDebtValueRay) return 0;

        // One new drawn share of the target adds drawnIndex * price * 10^(18-decimals) of debt Value, so the
        // room left under the ceiling divided by that is the new shares that fit, rounded down
        IAaveV4Spoke.Reserve memory targetReserve = spoke.getReserve(targetReserveId);
        uint256 valuePerDrawnShareRay = data.targetDrawnIndex * data.targetPrice * (10 ** (18 - targetReserve.decimals));
        uint256 maxNewDrawnShares = (maxDebtValueRay - data.totalDebtValueRay) / valuePerDrawnShareRay;
        // Aave stores drawn shares as uint120, so leave room next to the existing shares
        uint256 shareRoom = type(uint120).max - data.targetDrawnShares;
        if (maxNewDrawnShares > shareRoom) maxNewDrawnShares = shareRoom;
        return IAaveV4Hub(targetReserve.hub).previewDrawByShares(targetReserve.assetId, maxNewDrawnShares);
    }

    /**
     * @notice The safe's collateral headroom: the weighted collateral value it can lose while its health
     *         factor stays at or above `floor`
     * @dev Headroom is in the weighted-collateral value unit (amount * price * 10^(18 - decimals) *
     *      collateralFactorBps, the accumulator unit of Aave's own HF check). The required minimum rounds
     *      up: rounding down would let the exact max quote sit a hair past the floor and fail Aave's check.
     * @param spoke The Aave Spoke holding the position
     * @param safe The Safe whose position is measured
     * @param floor The health-factor floor to hold, in WAD (1e18 is Aave's raw executable bound)
     * @return The headroom in weighted-collateral value units, 0 when the position sits at or under the floor
     */
    function withdrawHeadroom(IAaveV4Spoke spoke, address safe, uint256 floor) external view returns (uint256) {
        BorrowCapacityData memory data = _accountData(spoke, safe);
        if (data.totalDebtValueRay == 0) return data.weightedCollateralValueBps;
        uint256 required = Math.mulDiv(data.totalDebtValueRay, floor, WEIGHTED_COLLATERAL_TO_DEBT_RAY, Math.Rounding.Ceil);
        return data.weightedCollateralValueBps > required ? data.weightedCollateralValueBps - required : 0;
    }

    /**
     * @notice Amount of `targetReserveId`'s asset the safe can withdraw while consuming at most `headroom`
     *         of weighted collateral value
     * @dev Supply that carries no borrowing power (collateral flag off, or a zero collateral factor) is
     *      fully withdrawable, matching Aave's own check. Otherwise the assets that must stay supplied are
     *      sized up (ceil), converted to shares up (previewRemoveByAssets), and the withdrawable remainder
     *      revalued down (previewRemoveByShares) — so withdrawing the quote never breaches the headroom
     *      under Aave's own share rounding.
     * @param spoke The Aave Spoke holding the position
     * @param safe The Safe whose position is measured
     * @param targetReserveId The reserve to withdraw from
     * @param headroom The weighted collateral value the withdrawal may consume (see withdrawHeadroom)
     * @return The withdrawable amount in asset units
     */
    function collateralForHeadroom(IAaveV4Spoke spoke, address safe, uint256 targetReserveId, uint256 headroom) external view returns (uint256) {
        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(targetReserveId);
        IAaveV4Hub hub = IAaveV4Hub(reserve.hub);
        uint256 suppliedShares = spoke.getUserPosition(targetReserveId, safe).suppliedShares;
        uint256 supplied = hub.previewRemoveByShares(reserve.assetId, suppliedShares);
        if (supplied == 0) return 0;

        uint256 weightPerAsset = _weightPerAsset(spoke, safe, targetReserveId, reserve);
        if (weightPerAsset == 0) return supplied;

        if (headroom >= supplied * weightPerAsset) return supplied;
        uint256 keepAssets = Math.ceilDiv(supplied * weightPerAsset - headroom, weightPerAsset);
        uint256 keepShares = hub.previewRemoveByAssets(reserve.assetId, keepAssets);
        if (keepShares >= suppliedShares) return 0;
        return hub.previewRemoveByShares(reserve.assetId, suppliedShares - keepShares);
    }

    /**
     * @notice The weighted collateral value withdrawing `amount` of `targetReserveId`'s asset consumes
     * @dev Exact against Aave's own share revaluation: the withdrawal's share burn rounds up and the
     *      remaining supply revalues down, so threading this across tokens never under-counts. Zero for
     *      supply carrying no borrowing power.
     * @param spoke The Aave Spoke holding the position
     * @param safe The Safe whose position is measured
     * @param targetReserveId The reserve being withdrawn from
     * @param amount The withdrawal in asset units
     * @return The consumed weighted collateral value (see withdrawHeadroom for the unit)
     */
    function headroomRemoved(IAaveV4Spoke spoke, address safe, uint256 targetReserveId, uint256 amount) external view returns (uint256) {
        if (amount == 0) return 0;
        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(targetReserveId);
        uint256 weightPerAsset = _weightPerAsset(spoke, safe, targetReserveId, reserve);
        if (weightPerAsset == 0) return 0;

        IAaveV4Hub hub = IAaveV4Hub(reserve.hub);
        uint256 suppliedShares = spoke.getUserPosition(targetReserveId, safe).suppliedShares;
        uint256 supplied = hub.previewRemoveByShares(reserve.assetId, suppliedShares);
        uint256 burnedShares = hub.previewRemoveByAssets(reserve.assetId, amount);
        if (burnedShares >= suppliedShares) return supplied * weightPerAsset;
        uint256 remaining = hub.previewRemoveByShares(reserve.assetId, suppliedShares - burnedShares);
        return (supplied - remaining) * weightPerAsset;
    }

    /**
     * @notice The weighted collateral value a borrow of `amount` requires at Aave's 1.00 health-factor bound
     * @dev A borrow adds amount * RAY * price * 10^(18 - decimals) of RAY debt Value; at the 1.00 bound the
     *      collateral requirement divides by 1e41 into an exact integer: amount * price * 10^(18 - decimals)
     *      * 10_000. Also the value a repay of `amount` frees.
     * @param spoke The Aave Spoke holding the reserve
     * @param targetReserveId The reserve being borrowed or repaid
     * @param amount The borrow or repay in asset units
     * @return The required weighted collateral value (see withdrawHeadroom for the unit)
     */
    function borrowValue(IAaveV4Spoke spoke, uint256 targetReserveId, uint256 amount) external view returns (uint256) {
        uint256 price = IAaveV4Oracle(spoke.ORACLE()).getReservePrice(targetReserveId);
        uint256 decimals = spoke.getReserve(targetReserveId).decimals;
        return amount * price * (10 ** (18 - decimals)) * 10_000;
    }

    /**
     * @notice The weighted collateral value a repay of `amount` of `targetReserveId`'s asset frees at Aave's
     *         1.00 health-factor bound
     * @dev Exact against Aave's own restore math (Spoke.repay via calculateRestoreAmount): the payment
     *      clears premium debt first — a sub-premium payment removes exactly amount * RAY of debt — and the
     *      drawn remainder restores shares rounded down, so the debt actually removed can sit a share short
     *      of the paid amount. Crediting the ideal borrowValue there would overstate the freed headroom and
     *      let an exact-boundary repay quote fail Aave's health check on its withdraw leg. The final
     *      conversion also rounds down, so the credit never exceeds what the repay actually frees.
     * @param spoke The Aave Spoke holding the position
     * @param safe The Safe whose debt is repaid
     * @param targetReserveId The reserve being repaid
     * @param amount The repay in asset units
     * @return The freed weighted collateral value (see withdrawHeadroom for the unit)
     */
    function repayValue(IAaveV4Spoke spoke, address safe, uint256 targetReserveId, uint256 amount) external view returns (uint256) {
        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(targetReserveId);
        uint256 drawnIndex = IAaveV4Hub(reserve.hub).getAssetDrawnIndex(reserve.assetId);
        uint256 premiumDebtRay = spoke.getUserPremiumDebtRay(targetReserveId, safe);

        // Mirrors UserPositionUtils.calculateRestoreAmount: premium (rounded up to asset units) is cleared
        // first, the drawn remainder restores shares rounded down (Spoke.repay's rayDivDown), capped at the
        // drawn shares held
        uint256 premiumDebt = Math.ceilDiv(premiumDebtRay, RAY);
        uint256 freedDebtRay;
        if (amount < premiumDebt) {
            freedDebtRay = amount * RAY;
        } else {
            uint256 restoredShares = ((amount - premiumDebt) * RAY) / drawnIndex;
            uint256 drawnShares = spoke.getUserPosition(targetReserveId, safe).drawnShares;
            if (restoredShares > drawnShares) restoredShares = drawnShares;
            freedDebtRay = premiumDebtRay + restoredShares * drawnIndex;
        }

        uint256 valueFactor = IAaveV4Oracle(spoke.ORACLE()).getReservePrice(targetReserveId) * (10 ** (18 - reserve.decimals));
        // The freed RAY debt Value over the 1.00-bound divisor (1e41 / 1e18 WAD), rounded down
        return Math.mulDiv(freedDebtRay, valueFactor, WEIGHTED_COLLATERAL_TO_DEBT_RAY / 1e18);
    }

    /**
     * @notice Amount of `targetReserveId`'s asset to supply as collateral so the position gains `value` of
     *         weighted collateral value, rounded up
     * @dev The inverse of the accumulator weighting: value / (price * 10^(18 - decimals) * collateralFactor),
     *      ceil so the error is always a hair of extra supply, never short headroom. Caller guarantees the
     *      reserve's collateral factor is nonzero.
     * @param spoke The Aave Spoke holding the reserve
     * @param targetReserveId The reserve being supplied
     * @param value The weighted collateral value to gain (see withdrawHeadroom for the unit)
     * @return The amount to supply in asset units
     */
    function collateralForValue(IAaveV4Spoke spoke, uint256 targetReserveId, uint256 value) external view returns (uint256) {
        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(targetReserveId);
        uint256 price = IAaveV4Oracle(spoke.ORACLE()).getReservePrice(targetReserveId);
        uint256 collateralFactor = spoke.getDynamicReserveConfig(targetReserveId, reserve.dynamicConfigKey).collateralFactor;
        return Math.ceilDiv(value, price * (10 ** (18 - reserve.decimals)) * collateralFactor);
    }

    /// @dev One asset's weighted collateral value per asset unit: price * 10^(18 - decimals) *
    ///      collateralFactorBps, or 0 when the supply carries no borrowing power (flag off or zero factor)
    function _weightPerAsset(IAaveV4Spoke spoke, address safe, uint256 targetReserveId, IAaveV4Spoke.Reserve memory reserve) private view returns (uint256) {
        (bool isCollateral,) = spoke.getUserReserveStatus(targetReserveId, safe);
        if (!isCollateral) return 0;
        uint256 collateralFactor = spoke.getDynamicReserveConfig(targetReserveId, reserve.dynamicConfigKey).collateralFactor;
        if (collateralFactor == 0) return 0;
        uint256 price = IAaveV4Oracle(spoke.ORACLE()).getReservePrice(targetReserveId);
        return price * (10 ** (18 - reserve.decimals)) * collateralFactor;
    }

    /// @dev The whole-position accumulators without a borrow target
    function _accountData(IAaveV4Spoke spoke, address safe) private view returns (BorrowCapacityData memory) {
        (uint256[] memory reserveIds, uint256[] memory prices) = _allReservesAndPrices(spoke);
        return _borrowCapacityData(spoke, safe, type(uint256).max, reserveIds, prices);
    }

    /// @dev Every reserve id in the Spoke paired with its Aave oracle price
    function _allReservesAndPrices(IAaveV4Spoke spoke) private view returns (uint256[] memory, uint256[] memory) {
        uint256 len = spoke.getReserveCount();
        uint256[] memory reserveIds = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            reserveIds[i] = i;
            unchecked {
                ++i;
            }
        }
        uint256[] memory prices = IAaveV4Oracle(spoke.ORACLE()).getReservesPrices(reserveIds);
        return (reserveIds, prices);
    }

    /// @dev Rebuilds the Aave values used by borrow health validation with current reserve configuration.
    function _borrowCapacityData(IAaveV4Spoke spoke, address safe, uint256 targetReserveId, uint256[] memory reserveIds, uint256[] memory prices) private view returns (BorrowCapacityData memory) {
        BorrowCapacityData memory data;
        for (uint256 i = 0; i < reserveIds.length;) {
            data = _addReserveCapacity(data, spoke, safe, reserveIds[i], prices[i], reserveIds[i] == targetReserveId);
            unchecked {
                ++i;
            }
        }
        return data;
    }

    /**
     * @dev Adds one reserve's collateral and debt to the running totals, mirroring the two accumulators in
     *      Aave's Spoke.getUserAccountData at full precision. Amounts become Aave "Value" units by
     *      amount * price * 10^(18 - decimals); collateral is further weighted by the reserve's
     *      collateralFactor (BPS) and debt stays in RAY.
     * @param data The running totals, returned with this reserve added
     * @param spoke The Aave Spoke holding the position
     * @param safe The Safe whose position is being summed
     * @param reserveId The Spoke reserve to add
     * @param price The reserve's Aave oracle price
     * @param isTarget Whether this is the reserve being borrowed, whose conversion inputs the caller needs
     * @return The updated totals
     */
    function _addReserveCapacity(BorrowCapacityData memory data, IAaveV4Spoke spoke, address safe, uint256 reserveId, uint256 price, bool isTarget) private view returns (BorrowCapacityData memory) {
        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(reserveId);
        IAaveV4Hub hub = IAaveV4Hub(reserve.hub);
        IAaveV4Spoke.UserPosition memory position = spoke.getUserPosition(reserveId, safe);
        (bool isCollateral, bool borrowed) = spoke.getUserReserveStatus(reserveId, safe);
        // Turns an asset amount into Aave Value units: amount * price * 10^(18 - decimals)
        uint256 valueFactor = price * (10 ** (18 - reserve.decimals));

        if (isCollateral && position.suppliedShares != 0) {
            uint256 collateralFactor = spoke.getDynamicReserveConfig(reserveId, reserve.dynamicConfigKey).collateralFactor;
            if (collateralFactor != 0) {
                // Aave rounds supplied shares to removable assets down, so collateral power is conservative
                uint256 suppliedAssets = hub.previewRemoveByShares(reserve.assetId, position.suppliedShares);
                // Collateral Value weighted by the factor (BPS), Aave's avgCollateralFactor accumulator
                data.weightedCollateralValueBps += suppliedAssets * valueFactor * collateralFactor;
            }
        }

        uint256 drawnIndex;
        if (borrowed || isTarget) drawnIndex = hub.getAssetDrawnIndex(reserve.assetId);
        if (borrowed) {
            // Keep drawn and premium debt at full RAY precision; do not round debt down to asset units
            uint256 debtRay = uint256(position.drawnShares) * drawnIndex + spoke.getUserPremiumDebtRay(reserveId, safe);
            data.totalDebtValueRay += debtRay * valueFactor;
        }

        if (isTarget) {
            // This is the reserve being borrowed. After the loop, borrowCapacity turns the remaining debt
            // budget into an amount of this asset, which needs its price, drawn index, and existing shares.
            // Save them now, while this iteration already holds them, instead of re-fetching after the loop.
            data.targetPrice = price;
            data.targetDrawnIndex = drawnIndex;
            data.targetDrawnShares = position.drawnShares;
        }
        return data;
    }
}
