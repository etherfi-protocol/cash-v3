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

    /**
     * @notice Returns the ERC-4626 vault a redirect of `token` must deposit into instead of
     *         transferring `token` itself, or the zero address when the token travels as-is.
     * @dev Read by `TopUp.redirectToTradingSafe` so that wrapping stays configuration rather
     *      than a parameter, leaving the redirect one call shape for every asset.
     * @param token Address of the ERC20 being redirected.
     */
    function wrapperFor(address token) external view returns (address);

    /**
     * @notice Returns the underlying an ERC-4626 `vault` is registered to be redeemed into, or
     *         the zero address when the vault may not be unwrapped.
     * @dev Read by `TopUp.unwrap`, so which vaults a TopUp may redeem stays configuration on the
     *      factory rather than state on each instance — the same arrangement as `wrapperFor`.
     * @param vault Address of the ERC-4626 vault being redeemed.
     */
    function unwrapAssetFor(address vault) external view returns (address);
}
