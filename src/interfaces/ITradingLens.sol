// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ITradingLens
 * @author ether.fi
 * @notice Minimal surface of the TradingLens supported-trading-token registry consumed by
 *         the TradingSafeFactory.
 */
interface ITradingLens {
    /**
     * @notice Returns whether `token` is in the supported-trading-token set.
     * @param token The token to check.
     * @return True if the token is a supported trading asset.
     */
    function isSupportedToken(address token) external view returns (bool);
}
