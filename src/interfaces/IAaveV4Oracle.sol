// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAaveV4Oracle
 * @notice The slice of the Aave v4 oracle that the AaveV4Lens reads.
 * @author ether.fi
 */
interface IAaveV4Oracle {
    /// @notice Returns the prices of the given reserves, in oracle base units (8-decimal USD).
    function getReservesPrices(uint256[] calldata reserveIds) external view returns (uint256[] memory);
}
