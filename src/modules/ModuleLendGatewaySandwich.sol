// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILendGateway } from "../interfaces/ILendGateway.sol";
import { ModuleCheckBalance } from "./ModuleCheckBalance.sol";

/**
 * @title ModuleLendGatewaySandwich
 * @notice Bookends for modules that move a safe's assets once auto-supply has parked them in Aave:
 *         withdraw the input back to the safe, run the action, re-supply the output as collateral.
 * @dev No health check of its own: Aave rejects any withdraw that would push the health factor below 1
 *      (its collateralFactor is both LTV and liquidation threshold), and the back bookend only adds
 *      collateral. Both bookends no-op unless _lendActive, so a legacy or opted-out safe is untouched.
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
     * @dev Virtual only for the test harness
     * @param safe The safe to test
     * @return True if the Aave bookends should run for the safe
     */
    function _lendActive(address safe) internal view virtual returns (bool) {
        return cashModule.isLendActive(safe);
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
        if (!_lendActive(safe)) return;
        ILendGateway lendGateway = gateway();
        uint256 supplied = lendGateway.suppliedOf(safe, asset);
        uint256 shortfall = amount - looseAvailable;
        if (shortfall > supplied) shortfall = supplied;
        if (shortfall != 0) lendGateway.withdraw(safe, asset, shortfall, safe);
    }

    /**
     * @notice Supplies an asset from the safe back into Aave and marks it as collateral, best-effort
     * @dev No-op for an unregistered asset. A rejected supply (frozen, paused, capped) is swallowed rather
     *      than reverting the action that already ran; the output stays loose and the next sweep restores it.
     * @param safe The safe whose position is credited
     * @param asset The asset to supply
     * @param amount The amount to supply
     */
    function _resupplyToGateway(address safe, address asset, uint256 amount) internal {
        if (!_lendActive(safe)) return;
        ILendGateway lendGateway = gateway();
        if (!lendGateway.isRegistered(asset)) return;
        try lendGateway.supply(safe, asset, amount) {
            lendGateway.setUsingAsCollateral(safe, asset, true);
        } catch { }
    }
}
