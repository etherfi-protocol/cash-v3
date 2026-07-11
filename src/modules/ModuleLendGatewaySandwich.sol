// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILendGateway } from "../interfaces/ILendGateway.sol";

/**
 * @title ModuleLendGatewaySandwich
 * @notice Shared helper for modules that move a safe's assets once those assets live in Aave.
 *         Auto-supply leaves the asset in the safe's Aave position, not the safe, so a module
 *         withdraws it back to the safe, runs its action, then re-supplies the output as collateral.
 * @dev Provides the two bookends; the module brackets its own action between them. Health is enforced
 *      by Aave itself: the Spoke rejects any collateral withdraw that would leave the position's health
 *      factor below 1, and with Aave v4's single collateralFactor (LTV and liquidation threshold are the
 *      same) that is exactly the under-LTV bound. The back bookend only ever adds collateral, so the
 *      post-op position can never be worse than what Aave validated at withdraw time; no extra check here.
 *
 *      The helper holds no state: the consumer supplies the gateway (resolved live from the CashModule,
 *      its single source of truth) and the _lendActive predicate. Every bookend sits behind _lendActive,
 *      which short-circuits on usesLendGateway before reading the gateway, so a legacy safe or an unset
 *      gateway is never dereferenced.
 * @author ether.fi
 */
abstract contract ModuleLendGatewaySandwich {
    /**
     * @notice The lend gateway the bookends drive
     * @dev A consumer resolves it live from the CashModule (`cashModule.getLendGateway()`), the gateway
     *      address's single source of truth, rather than capturing it at deploy.
     * @return The lend gateway
     */
    function gateway() public view virtual returns (ILendGateway);

    /**
     * @notice Whether the sandwich should touch Aave for `safe`
     * @dev A consumer must return true only when the safe's assets actually live in Aave: the safe is on
     *      the gateway engine (usesLendGateway) and has not opted out (isLendEnabled). A legacy safe reports
     *      isLendEnabled true yet keeps its assets loose under DebtManager, so gating on isLendEnabled alone
     *      would re-supply a legacy safe's output into Aave where DebtManager cannot see it. Consumers test
     *      usesLendGateway first, which is false (and short-circuits) for a legacy safe, so the gateway is
     *      only read once the safe is known to be on it. Left abstract so every consumer states the predicate.
     * @param safe The safe to test
     * @return True if the Aave bookends should run for the safe
     */
    function _lendActive(address safe) internal view virtual returns (bool);

    /**
     * @notice Pulls the part of `amount` not already loose in the safe out of its Aave position
     * @dev Sizes the withdraw at min(amount - looseAvailable, supplied) so it never asks Aave for more than
     *      the safe supplied and never touches an unsupplied or unregistered asset (suppliedOf is zero for
     *      both, so ETH and non-reserve inputs stay untouched). The caller passes `looseAvailable` (the loose
     *      balance net of reservations) since the reservation view lives on the module, not the helper.
     *      A safe whose assets do not live in Aave has nothing to pull back, so this is a no-op for it.
     *      Aave reverts if the withdraw would drop the position's health factor below 1 (its collateralFactor
     *      doubles as LTV and liquidation threshold), so the operation cannot leave the safe over-LTV.
     * @param safe The safe whose position is debited
     * @param asset The asset to make available
     * @param amount The total amount the operation needs loose in the safe
     * @param looseAvailable The loose balance already usable in the safe (balance net of pending-withdrawal reservations)
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
     * @notice Supplies an asset from the safe back into Aave and marks it as collateral
     * @dev No-op for a safe whose assets do not live in Aave, and for an asset the gateway does not list as a
     *      reserve (the gateway would reject the supply); in both cases the output stays loose in the safe.
     * @param safe The safe whose position is credited
     * @param asset The asset to supply
     * @param amount The amount to supply
     */
    function _resupplyToGateway(address safe, address asset, uint256 amount) internal {
        if (!_lendActive(safe)) return;
        ILendGateway lendGateway = gateway();
        if (!lendGateway.isRegistered(asset)) return;
        lendGateway.supply(safe, asset, amount);
        lendGateway.setUsingAsCollateral(safe, asset, true);
    }
}
