// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ITradingSafeBridgeReceiver
 * @author ether.fi
 * @notice Surface that a destination-chain TradingSafe MUST expose so that
 *         `OwnershipBridgeReceiver` can replay owner-mutating operations on it.
 * @dev Implementers gate each of these functions to be callable only by the
 *      `OwnershipBridgeReceiver` (privileged role). The bridge receiver carries the
 *      source-side intent verbatim — no sigs are re-verified here.
 */
interface ITradingSafeBridgeReceiver {
    /**
     * @notice Apply a bridged `configureOwners` update on the TradingSafe.
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner add (true) / remove (false) flag.
     * @param threshold New signature threshold.
     */
    function applyBridgeConfigureOwners(address[] calldata owners, bool[] calldata shouldAdd, uint8 threshold) external;

    /**
     * @notice Apply a bridged `setThreshold` update on the TradingSafe.
     * @param threshold New signature threshold.
     */
    function applyBridgeSetThreshold(uint8 threshold) external;

    /**
     * @notice Apply a bridged `recover` (timelocked owner replacement) on the TradingSafe.
     * @param newOwner Incoming owner that will take effect after the local timelock.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which `newOwner` should activate.
     *        The TradingSafe MUST adopt this exact activation time rather than computing a local one,
     *        so the source and destination timelocks stay synchronized.
     */
    function applyBridgeRecover(address newOwner, uint256 incomingOwnerEffectiveAt) external;

    /// @notice Apply a bridged `cancelRecovery` on the TradingSafe (clears pending incoming-owner state).
    function applyBridgeCancelRecovery() external;
}
