// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGateway } from "../interfaces/IGateway.sol";

/**
 * @title ModuleGatewaySandwich
 * @notice Shared helper for modules that move a safe's assets once those assets live in Aave.
 *         Auto-supply leaves the asset in the safe's Aave position, not the safe, so a module
 *         withdraws it back to the safe, runs its action, then re-supplies the output as collateral.
 * @dev Provides the two bookends and the health guard; the module brackets its own action between
 *      them. The withdraw guard reverts when the post-withdraw health factor is below minHealthFactor,
 *      matching Aave's own check that debt-backing collateral cannot be withdrawn (no deferral).
 * @author ether.fi
 */
abstract contract ModuleGatewaySandwich {
    /// @notice The gateway that performs Aave ops on a safe's behalf
    IGateway public immutable gateway;
    /// @notice The lowest post-withdraw health factor a withdraw may leave the safe at
    uint256 public immutable minHealthFactor;

    /// @notice Thrown when the gateway address is zero
    error InvalidGateway();
    /// @notice Thrown when a withdraw would leave the safe below minHealthFactor
    error WithdrawBreachesHealth();

    constructor(address _gateway, uint256 _minHealthFactor) {
        if (_gateway == address(0)) revert InvalidGateway();
        gateway = IGateway(_gateway);
        minHealthFactor = _minHealthFactor;
    }

    /**
     * @notice Withdraws an asset from the safe's Aave position back into the safe, then guards health
     * @param safe The safe whose position is debited
     * @param asset The asset to withdraw
     * @param amount The amount to withdraw
     */
    function _withdrawFromGateway(address safe, address asset, uint256 amount) internal {
        gateway.withdraw(safe, asset, amount, safe);
        if (gateway.getAccountData(safe).healthFactor < minHealthFactor) revert WithdrawBreachesHealth();
    }

    /**
     * @notice Supplies an asset from the safe back into Aave and marks it as collateral
     * @param safe The safe whose position is credited
     * @param asset The asset to supply
     * @param amount The amount to supply
     */
    function _resupplyToGateway(address safe, address asset, uint256 amount) internal {
        gateway.supply(safe, asset, amount);
        gateway.setUsingAsCollateral(safe, asset, true);
    }
}
