// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICCTPTokenMinter
 * @notice Interface for Circle CCTP TokenMinter contract
 * @dev Based on Circle's TokenMinterV2. Exposes the per-message burn cap enforced by
 *      TokenMessenger.depositForBurn; read via messenger.localMinter().burnLimitsPerMessage(token).
 * @author ether.fi
 */
interface ICCTPTokenMinter {
    /// @notice Per-token cap on a single depositForBurn message (in the token's own units).
    function burnLimitsPerMessage(address token) external view returns (uint256);
}
