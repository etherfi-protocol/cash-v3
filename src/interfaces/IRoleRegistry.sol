// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IRoleRegistry
 * @notice Interface for role-based access control management
 * @dev Provides functions for managing and querying role assignments
 * @custom:security Implements role-based access control for protocol permissions
 */
interface IRoleRegistry {
    /**
     * @notice Verifies if an account has pauser privileges
     * @param account The address to check for pauser role
     */
    function onlyPauser(address account) external view;

    /**
     * @notice Verifies if an account has unpauser privileges
     * @param account The address to check for unpauser role
     */
    function onlyUnpauser(address account) external view;

    /**
     * @notice Checks if an account has any of the specified roles
     * @dev Reverts if the account doesn't have at least one of the roles
     * @param account The address to check roles for
     * @param encodedRoles ABI encoded roles using abi.encode(ROLE_1, ROLE_2, ...)
     * @custom:throws Reverts if account has none of the specified roles
     */
    function checkRoles(address account, bytes memory encodedRoles) external view;

    /**
     * @notice Checks if an account has a specific role
     * @dev Direct query for a single role status
     * @param role The role identifier to check
     * @param account The address to check the role for
     * @return True if the account has the role, false otherwise
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @notice Grants a role to an account
     * @dev Only callable by the contract owner
     * @param role The role identifier to grant
     * @param account The address to grant the role to
     * @custom:access Restricted to contract owner
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @notice Revokes a role from an account
     * @dev Only callable by the contract owner
     * @param role The role identifier to revoke
     * @param account The address to revoke the role from
     * @custom:access Restricted to contract owner
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @notice Retrieves all addresses that have a specific role
     * @dev Wrapper around EnumerableRoles roleHolders function
     * @param role The role identifier to query
     * @return Array of addresses that have the specified role
     */
    function roleHolders(bytes32 role) external view returns (address[] memory);

    /**
     * @notice Verifies if an account has upgrader privileges
     * @dev Used for upgrade authorization checks
     * @param account The address to check for upgrader role
     * @custom:throws Reverts if account is not an authorized upgrader
     */
    function onlyUpgrader(address account) external view;
}
