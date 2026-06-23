// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITopUpFactory
 * @author ether.fi
 * @notice Read surface that per-user `TopUp` instances consume from their factory owner.
 *         Defined here so the TopUp impl can stay decoupled from the full factory contract.
 */
interface ITopUpFactory {
    /**
     * @notice Returns whether `token` is configured as a bridge-supported token on this
     *         factory. Used by `TopUpV2.executeRecovery` to gate recovery to non-supported
     *         tokens only (supported tokens must use the normal claim path).
     * @param token Address of the ERC20 to check.
     */
    function isTokenSupported(address token) external view returns (bool);

    /**
     * @notice Returns the destination-chain TradingSafe address that `topUp` redirects to,
     *         derived from the per-TopUp `sourceSafe` binding + the factory's configured
     *         `TradingSafeFactory`. Reverts if either is missing.
     * @dev Called by `TopUp.redirectToTradingSafe`. Pure factory-side resolution keeps the
     *      TopUp impl stateless.
     * @param topUp The per-user TopUp instance.
     */
    function redirectDestinationFor(address topUp) external view returns (address);
}
