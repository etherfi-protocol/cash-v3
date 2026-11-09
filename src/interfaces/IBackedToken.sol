// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IBackedToken
 * @notice The slice of Backed's rebasing xStock that converts a displayed amount into the shares a transfer moves.
 * @author ether.fi
 */
interface IBackedToken {
    /// @notice Shares the token moves for a transfer of `amount`, rounded down
    function getSharesByUnderlyingAmount(uint256 amount) external view returns (uint256);
}
