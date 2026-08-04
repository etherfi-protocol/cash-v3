// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { IAaveV4Hub } from "../../../../../src/interfaces/IAaveV4Hub.sol";
import { IAaveV4Oracle } from "../../../../../src/interfaces/IAaveV4Oracle.sol";
import { IAaveV4Spoke } from "../../../../../src/interfaces/IAaveV4Spoke.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

/**
 * @title BorrowCapacityDryRun
 * @notice Not a regression test: a step-by-step re-derivation of LendGateway._borrowCapacity with every
 *         intermediate logged, asserted equal to the gateway's own answer, then proven against real Aave by
 *         borrowing the exact raw quote (succeeds) and one more base unit (reverts).
 */
contract BorrowCapacityDryRunTest is CashGatewayTestSetup {
    uint256 internal constant WEIGHTED_COLLATERAL_TO_DEBT_RAY = 1e41;

    struct Acc {
        uint256 weightedCollateralValueBps;
        uint256 totalDebtValueRay;
        uint256 targetPrice;
        uint256 targetDrawnIndex;
        uint256 targetDrawnShares;
    }

    function test_dryRun_borrowCapacity() public {
        // ------------------------------------------------------------ scenario
        // 1 weETH collateral, 400 USDC debt, 20 days of interest accrual, 1.05 HF floor
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 400e6);
        vm.warp(block.timestamp + 20 days);
        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);

        IAaveV4Spoke sp = IAaveV4Spoke(address(spoke));
        uint256 len = sp.getReserveCount();
        console2.log("=== position: 1 weETH supplied, 400 USDC borrowed, +20 days, floor 1.05e18 ===");
        console2.log("reserveCount", len);

        // ------------------------------------------------------------ step 2: accumulate over all reserves
        uint256[] memory reserveIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) reserveIds[i] = i;
        uint256[] memory prices = IAaveV4Oracle(sp.ORACLE()).getReservesPrices(reserveIds);

        uint256 targetReserveId = gw.reserveIdOf(address(usdc));
        Acc memory acc;
        for (uint256 i = 0; i < len; i++) {
            acc = _addReserve(acc, sp, i, prices[i], i == targetReserveId);
        }

        console2.log("=== accumulators ===");
        console2.log("weightedCollateralValueBps", acc.weightedCollateralValueBps);
        console2.log("  (~USD: /1e26/1e4)", acc.weightedCollateralValueBps / 1e26 / 1e4);
        console2.log("totalDebtValueRay", acc.totalDebtValueRay);
        console2.log("  (~USD: /1e26/1e27)", acc.totalDebtValueRay / 1e26 / 1e27);

        // ------------------------------------------------------------ steps 3-5 for both floors
        IAaveV4Spoke.Reserve memory target = sp.getReserve(targetReserveId);
        uint256 valuePerDrawnShareRay = acc.targetDrawnIndex * acc.targetPrice * (10 ** (18 - target.decimals));
        console2.log("valuePerDrawnShareRay", valuePerDrawnShareRay);

        uint256 buffered = _tail(acc, valuePerDrawnShareRay, target, 1.05e18, "floor=1.05");
        uint256 raw = _tail(acc, valuePerDrawnShareRay, target, 1e18, "floor=1.00");

        assertEq(gw.borrowCapacity(address(safe), address(usdc)), buffered, "manual buffered == gateway borrowCapacity");
        assertEq(gw.rawBorrowCapacity(address(safe), address(usdc)), raw, "manual raw == gateway rawBorrowCapacity");
        console2.log("=== gateway agrees: borrowCapacity / rawBorrowCapacity ===", buffered, raw);

        // ------------------------------------------------------------ prove the bound on real Aave
        IAaveV4Spoke.UserAccountData memory before = sp.getUserAccountData(address(safe));
        console2.log("Aave healthFactor before (WAD)", before.healthFactor);
        console2.log("Aave totalDebtValueRay before  ", before.totalDebtValueRay);
        assertEq(before.totalDebtValueRay, acc.totalDebtValueRay, "debt accumulator matches Aave's view");

        _borrowOnGateway(address(safe), address(usdc), raw, recipient);
        IAaveV4Spoke.UserAccountData memory afterData = sp.getUserAccountData(address(safe));
        console2.log("borrowed exact raw quote:", raw);
        console2.log("Aave healthFactor after (WAD)", afterData.healthFactor);
        assertGe(afterData.healthFactor, 1e18, "exact raw quote lands at/above 1.00");

        vm.expectRevert();
        _borrowOnGateway(address(safe), address(usdc), 1, recipient);
        console2.log("borrowing 1 more base unit: reverted (HF would drop below 1.00)");
    }

    /// Same walk as above, but with a 20% collateralRisk on weETH so the safe carries non-zero premium debt:
    /// the scenario of test_borrowCapacity_countsAccruedPremiumDebt, with every intermediate logged.
    function test_dryRun_borrowCapacity_withPremium() public {
        vm.prank(aaveAdmin);
        spoke.updateReserveConfig(weethReserveId, ISpoke.ReserveConfig({ paused: false, frozen: false, borrowable: false, receiveSharesEnabled: true, collateralRisk: 2000 }));

        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 400e6);
        vm.warp(block.timestamp + 20 days);

        IAaveV4Spoke sp = IAaveV4Spoke(address(spoke));
        console2.log("=== premium scenario: weETH collateralRisk=2000 BPS, 1 weETH / 400 USDC, +20 days, no floor ===");

        uint256 len = sp.getReserveCount();
        uint256[] memory reserveIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) reserveIds[i] = i;
        uint256[] memory prices = IAaveV4Oracle(sp.ORACLE()).getReservesPrices(reserveIds);

        uint256 targetReserveId = gw.reserveIdOf(address(usdc));
        Acc memory acc;
        for (uint256 i = 0; i < len; i++) {
            acc = _addReserve(acc, sp, i, prices[i], i == targetReserveId);
        }

        console2.log("=== accumulators ===");
        console2.log("weightedCollateralValueBps", acc.weightedCollateralValueBps);
        console2.log("totalDebtValueRay", acc.totalDebtValueRay);

        IAaveV4Spoke.Reserve memory target = sp.getReserve(targetReserveId);
        uint256 valuePerDrawnShareRay = acc.targetDrawnIndex * acc.targetPrice * (10 ** (18 - target.decimals));
        console2.log("valuePerDrawnShareRay", valuePerDrawnShareRay);

        uint256 quote = _tail(acc, valuePerDrawnShareRay, target, 1e18, "floor=1.00");
        assertEq(gw.rawBorrowCapacity(address(safe), address(usdc)), quote, "manual == gateway rawBorrowCapacity");
        assertEq(gw.borrowCapacity(address(safe), address(usdc)), quote, "no floor set: buffered == raw");
        console2.log("=== gateway agrees: capacity ===", quote);

        // Counterfactual: the quote the gateway would give if it ignored premium debt
        uint256 premiumValueRay = sp.getUserPremiumDebtRay(targetReserveId, address(safe)) * (acc.targetPrice * (10 ** (18 - target.decimals)));
        Acc memory noPremium = acc;
        noPremium.totalDebtValueRay -= premiumValueRay;
        uint256 wrongQuote = _tail(noPremium, valuePerDrawnShareRay, target, 1e18, "counterfactual: premium ignored");
        console2.log("overquote if premium were ignored (USDC units)", wrongQuote - quote);

        _borrowOnGateway(address(safe), address(usdc), quote, recipient);
        console2.log("borrowed exact quote:", quote);
        console2.log("Aave healthFactor after (WAD)", sp.getUserAccountData(address(safe)).healthFactor);

        vm.expectRevert();
        _borrowOnGateway(address(safe), address(usdc), 1, recipient);
        console2.log("borrowing 1 more base unit: reverted");
    }

    /// @dev Mirrors LendGateway._addReserveCapacity, logging each piece.
    function _addReserve(Acc memory acc, IAaveV4Spoke sp, uint256 reserveId, uint256 price, bool isTarget) internal view returns (Acc memory) {
        IAaveV4Spoke.Reserve memory reserve = sp.getReserve(reserveId);
        IAaveV4Spoke.UserPosition memory position = sp.getUserPosition(reserveId, address(safe));
        (bool isCollateral, bool borrowed) = sp.getUserReserveStatus(reserveId, address(safe));
        uint256 valueFactor = price * (10 ** (18 - reserve.decimals));

        console2.log("---- reserve", reserveId, reserve.underlying);
        console2.log("  oraclePrice (8dec) / valueFactor", price, valueFactor);
        console2.log("  suppliedShares / drawnShares", position.suppliedShares, position.drawnShares);
        console2.log("  isCollateral / borrowed", isCollateral, borrowed);

        if (isCollateral && position.suppliedShares != 0) {
            uint256 collateralFactor = sp.getDynamicReserveConfig(reserveId, reserve.dynamicConfigKey).collateralFactor;
            if (collateralFactor != 0) {
                uint256 suppliedAssets = IAaveV4Hub(reserve.hub).previewRemoveByShares(reserve.assetId, position.suppliedShares);
                console2.log("  collateralFactor (BPS)", collateralFactor);
                console2.log("  suppliedAssets (previewRemoveByShares, down)", suppliedAssets);
                console2.log("  collateralValue (Value, 1e26=$1)", suppliedAssets * valueFactor);
                acc.weightedCollateralValueBps += suppliedAssets * valueFactor * collateralFactor;
                console2.log("  += weightedCollateralValueBps ->", acc.weightedCollateralValueBps);
            }
        }

        uint256 drawnIndex;
        if (borrowed || isTarget) {
            drawnIndex = IAaveV4Hub(reserve.hub).getAssetDrawnIndex(reserve.assetId);
            console2.log("  drawnIndex (RAY)", drawnIndex);
        }
        if (borrowed) {
            uint256 premiumDebtRay = sp.getUserPremiumDebtRay(reserveId, address(safe));
            uint256 debtRay = uint256(position.drawnShares) * drawnIndex + premiumDebtRay;
            console2.log("  premiumDebtRay", premiumDebtRay);
            console2.log("  debtRay = drawnShares*index + premium =", debtRay);
            acc.totalDebtValueRay += debtRay * valueFactor;
            console2.log("  += totalDebtValueRay ->", acc.totalDebtValueRay);
        }
        if (isTarget) {
            acc.targetPrice = price;
            acc.targetDrawnIndex = drawnIndex;
            acc.targetDrawnShares = position.drawnShares;
        }
        return acc;
    }

    /// @dev Mirrors _borrowCapacity's tail: debt ceiling, share budget, uint120 clamp, shares -> assets.
    function _tail(Acc memory acc, uint256 valuePerDrawnShareRay, IAaveV4Spoke.Reserve memory target, uint256 floor, string memory label) internal view returns (uint256) {
        console2.log("=== tail:", label, "===");
        uint256 maxDebtValueRay = (acc.weightedCollateralValueBps * WEIGHTED_COLLATERAL_TO_DEBT_RAY) / floor;
        console2.log("  maxDebtValueRay", maxDebtValueRay);
        console2.log("    (~USD)", maxDebtValueRay / 1e26 / 1e27);
        if (acc.totalDebtValueRay >= maxDebtValueRay) return 0;
        uint256 room = maxDebtValueRay - acc.totalDebtValueRay;
        console2.log("  room (Value*RAY)", room);
        uint256 maxNewDrawnShares = room / valuePerDrawnShareRay;
        console2.log("  maxNewDrawnShares", maxNewDrawnShares);
        uint256 shareRoom = type(uint120).max - acc.targetDrawnShares;
        if (maxNewDrawnShares > shareRoom) maxNewDrawnShares = shareRoom;
        uint256 amount = IAaveV4Hub(target.hub).previewDrawByShares(target.assetId, maxNewDrawnShares);
        console2.log("  previewDrawByShares -> capacity (asset units)", amount);
        return amount;
    }
}
