// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILendGateway } from "../interfaces/ILendGateway.sol";
import { ModuleCheckBalance } from "./ModuleCheckBalance.sol";

/**
 * @title ModuleLendGatewaySandwich
 * @notice Bookends for modules that move a safe's assets once auto-supply has parked them in Aave:
 *         withdraw the input back to the safe, run the action, re-supply the output as collateral.
 * @dev Aave rejects any withdraw that would push the health factor below 1 (its collateralFactor is both
 *      LTV and liquidation threshold), and the back bookend only adds collateral. On top of that,
 *      risk-increasing consumer flows end with _ensureGatewayFloor: whatever the resupply put back, the
 *      end state must sit at or above the gateway's configured health-factor floor (a failed or
 *      unregistered resupply otherwise leaves the health factor between Aave's 1.0 limit and the floor).
 *      Repayment flows (the LiquidUSD liquifier) are deliberately exempt: de-risking must never be
 *      blocked. Gating is asymmetric by design: the WITHDRAW bookend runs for any gateway-engine safe —
 *      an opted-out safe (including a matured opt-out whose unwind open borrows still block) can hold
 *      funds supplied on Aave, and pulling them loose is an exit op the repayment/exit paths depend on
 *      (repayUsingLiquidUSD sourcing supplied LiquidUSD). The RESUPPLY bookend and the floor check stay
 *      on _lendActive, so no new supply reaches Aave for a legacy or opted-out safe.
 *
 *      Inherits ModuleCheckBalance because the bookends extend its balance model (the front bookend
 *      sources what _getAvailableAmount found missing) and it holds the cashModule reference every
 *      consumer already has. Abstract, compiled into each consumer, never deployed on its own; changes
 *      ship by redeploying the consumers.
 * @author ether.fi
 */
abstract contract ModuleLendGatewaySandwich is ModuleCheckBalance {
    /**
     * @notice The lend gateway the bookends drive, resolved live from the CashModule
     * @dev Virtual only for the test harness, which pins a mock
     * @return The lend gateway
     */
    function gateway() public view virtual returns (ILendGateway) {
        return cashModule.getLendGateway();
    }

    /**
     * @notice Whether the safe's assets live in Aave: on the gateway engine and not opted out
     * @dev Virtual only for the test harness. Gates the resupply bookend and the floor check.
     * @param safe The safe to test
     * @return True if new supply may reach Aave for the safe
     */
    function _lendActive(address safe) internal view virtual returns (bool) {
        return cashModule.isLendActive(safe);
    }

    /**
     * @notice Whether the safe runs on the gateway engine, regardless of its opt-out state
     * @dev Virtual only for the test harness. Gates the withdraw bookend: an opted-out safe can still
     *      hold funds supplied on Aave (a matured opt-out blocked by open borrows, or a residual after
     *      processing), and reclaiming them is an exit op that must stay open.
     * @param safe The safe to test
     * @return True if the safe's supplied funds may sit in the gateway
     */
    function _onGatewayEngine(address safe) internal view virtual returns (bool) {
        return cashModule.usesLendGateway(safe);
    }

    /**
     * @notice Pulls the part of `amount` not already loose in the safe out of its Aave position
     * @dev Withdraws min(amount - looseAvailable, supplied), so an unsupplied or unregistered asset (ETH
     *      included) is untouched. Aave rejects a withdraw that would push the health factor below 1.
     * @param safe The safe whose position is debited
     * @param asset The asset to make available
     * @param amount The total amount the operation needs loose in the safe
     * @param looseAvailable The loose balance already usable in the safe (net of pending-withdrawal reservations)
     */
    function _withdrawShortfall(address safe, address asset, uint256 amount, uint256 looseAvailable) internal {
        if (amount <= looseAvailable) return;
        // Engine-gated, NOT _lendActive: an opted-out safe's supplied funds must stay reclaimable
        if (!_onGatewayEngine(safe)) return;
        ILendGateway lendGateway = gateway();
        if (address(lendGateway) == address(0)) return;
        uint256 supplied = lendGateway.suppliedOf(safe, asset);
        uint256 shortfall = amount - looseAvailable;
        if (shortfall > supplied) shortfall = supplied;
        if (shortfall != 0) lendGateway.withdraw(safe, asset, shortfall, safe);
    }

    /**
     * @notice Supplies an asset from the safe back into Aave and tries to mark it as collateral, best-effort
     * @dev No-op for an unregistered asset. A rejected supply (frozen, paused, capped) is swallowed rather
     *      than reverting the action that already ran. If only the collateral toggle fails, the supply remains
     *      earning yield and the gateway emits CollateralEnablementFailed for monitoring.
     * @param safe The safe whose position is credited
     * @param asset The asset to supply
     * @param amount The amount to supply
     */
    function _resupplyToGateway(address safe, address asset, uint256 amount) internal {
        if (!_lendActive(safe)) return;
        ILendGateway lendGateway = gateway();
        if (!lendGateway.isRegistered(asset)) return;
        try lendGateway.supplyAndTryEnableCollateral(safe, asset, amount) returns (bool) { } catch { }
    }

    /**
     * @notice Post-op health-factor floor check for risk-increasing consumer flows
     * @dev Called at the very end of an operation that may have pulled collateral out of Aave: the
     *      module's signed amount is not bound to the lens quote, and a failed or unregistered resupply
     *      can leave the health factor between Aave's 1.0 limit and the configured floor — this makes the
     *      end state take the floor. Repayment flows are deliberately exempt (de-risking must never be
     *      blocked). No-op for legacy or opted-out safes (their ops only touch loose, non-collateral
     *      funds) and while the floor is disabled.
     * @param safe The safe to check
     */
    function _ensureGatewayFloor(address safe) internal view {
        if (!_lendActive(safe)) return;
        gateway().ensureMinHealthFactor(safe);
    }
}
