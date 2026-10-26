// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAaveV4Spoke } from "../../interfaces/IAaveV4Spoke.sol";

/**
 * @title LendReserveLib
 * @notice The LendGateway's reserve-registry checks against the Spoke.
 * @dev Deployed once and linked into the LendGateway, so this logic does not count against its EIP-170
 *      runtime code-size limit. Storage-free: the gateway passes in what it holds and keeps the writes.
 *      Errors share names with the gateway's, so callers see the same selectors.
 * @author ether.fi
 */
library LendReserveLib {
    /// @notice Thrown when a zero address is supplied where one is not allowed
    error ZeroAddress();
    /// @notice Thrown when a reserveId's underlying does not match the asset being registered
    error ReserveAssetMismatch();
    /// @notice Thrown when changing or removing a reserve that still has outstanding debt or supplied balance
    error ReserveStillInUse();

    /**
     * @notice Validates registering `asset` at `reserveId`
     * @param spoke The Aave Spoke
     * @param asset The underlying asset
     * @param reserveId The Aave reserveId to register
     * @param registered Whether the asset is already registered
     * @param currentReserveId The asset's current reserveId (ignored when not registered)
     * @return changed False when the asset is already registered at `reserveId` (a no-op)
     */
    function validateRegistration(IAaveV4Spoke spoke, address asset, uint256 reserveId, bool registered, uint256 currentReserveId) external view returns (bool changed) {
        if (asset == address(0)) revert ZeroAddress();
        if (spoke.getReserve(reserveId).underlying != asset) revert ReserveAssetMismatch();
        if (registered) {
            if (currentReserveId == reserveId) return false;
            requireUnused(spoke, currentReserveId);
        }
        return true;
    }

    /**
     * @notice Reverts while a reserve has outstanding debt or supplied balance
     * @param spoke The Aave Spoke
     * @param reserveId The reserve to check
     */
    function requireUnused(IAaveV4Spoke spoke, uint256 reserveId) public view {
        if (spoke.getReserveTotalDebt(reserveId) != 0 || spoke.getReserveSuppliedAssets(reserveId) != 0) revert ReserveStillInUse();
    }
}
