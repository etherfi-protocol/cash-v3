// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGateway } from "../interfaces/IGateway.sol";

/**
 * @title ModuleGatewaySandwich
 * @notice Shared helper for modules that move a safe's assets once those assets live in Aave.
 *         Auto-supply leaves the asset in the safe's Aave position, not the safe, so a module
 *         withdraws it back to the safe, runs its action, then re-supplies the output as collateral.
 * @dev Provides the two bookends plus a guardsHealth modifier; the module brackets its own action
 *      between the bookends and applies guardsHealth to the operation's entry point. Aave enforces its
 *      own liquidation-threshold floor on the withdraw itself (it reverts if the withdraw alone would
 *      drop health below that threshold, no deferral). The stricter minHealthFactor buffer is checked
 *      once by guardsHealth, after the whole operation completes, against the safe's final position, so
 *      a transient mid-sandwich dip (collateral out, output not yet back) does not false-revert. It runs
 *      whatever the operation ends with (resupply, repay, borrow, send-out) and even on an early return.
 * @author ether.fi
 */
abstract contract ModuleGatewaySandwich {
    /// @notice The gateway that performs Aave ops on a safe's behalf
    IGateway public immutable gateway;
    /// @notice The lowest health factor the operation may leave the safe at once it completes
    uint256 public immutable minHealthFactor;

    /// @notice Thrown when the gateway address is zero
    error InvalidGateway();
    /// @notice Thrown when the completed operation would leave the safe below minHealthFactor
    error OperationBreachesHealth();

    /**
     * @notice Reverts if the operation leaves the safe below minHealthFactor
     * @dev Apply to a module's operation entry point. The check runs after the function body, against the
     *      final position, so it covers operations that end by resupplying, repaying, borrowing, or
     *      sending out, and runs even if the body returns early.
     * @param safe The safe whose final health is guarded
     */
    modifier guardsHealth(address safe) {
        _;
        if (gateway.getAccountData(safe).healthFactor < minHealthFactor) revert OperationBreachesHealth();
    }

    constructor(address _gateway, uint256 _minHealthFactor) {
        if (_gateway == address(0)) revert InvalidGateway();
        gateway = IGateway(_gateway);
        minHealthFactor = _minHealthFactor;
    }

    /**
     * @notice Withdraws an asset from the safe's Aave position back into the safe
     * @dev Aave reverts if the withdraw alone would breach its liquidation threshold; the stricter
     *      minHealthFactor buffer is enforced by guardsHealth on the operation, against the final position.
     * @param safe The safe whose position is debited
     * @param asset The asset to withdraw
     * @param amount The amount to withdraw
     */
    function _withdrawFromGateway(address safe, address asset, uint256 amount) internal {
        gateway.withdraw(safe, asset, amount, safe);
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
