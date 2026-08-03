// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IBlacklister
 * @notice Deliberately narrow consumer interface for the Blacklister singleton — consumers
 *         can only read the gate, never mutate it
 */
interface IBlacklister {
    /**
     * @notice Reverts with BlacklistedUser if the user is blacklisted, passes otherwise
     * @param user Address to check
     */
    function nonBlacklisted(address user) external view;

    /**
     * @notice Returns whether the user is currently blacklisted
     * @param user Address to check
     */
    function isBlacklisted(address user) external view returns (bool);

    /**
     * @notice Returns the timestamp (exclusive) until which the user is blacklisted
     * @param user Address to check
     */
    function blacklistedUntil(address user) external view returns (uint256);
}
