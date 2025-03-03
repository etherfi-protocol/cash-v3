// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IRoleRegistry
 * @notice Interface for role-based access control management
 * @dev Provides functions for managing and querying role assignments
 */
interface IRoleRegistry {
    /**
     * @notice Verifies if an account has pauser privileges
     * @param account The address to check for pauser role
     * @custom:throws Reverts if account is not an authorized pauser
     */
    function onlyPauser(address account) external view;

    /**
     * @notice Verifies if an account has unpauser privileges
     * @param account The address to check for unpauser role
     * @custom:throws Reverts if account is not an authorized unpauser
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

    /**
     * @notice Generates a unique role identifier for safe administrators
     * @dev Creates a unique bytes32 identifier by hashing the safe address with a role type
     * @param safe The address of the safe for which to generate the admin role
     * @return bytes32 A unique role identifier for the specified safe's admins
     * @custom:throws InvalidInput if safe is a zero address
     */
    function getSafeAdminRole(address safe) external pure returns (bytes32);

    /**
     * @notice Configures admin roles for a specific safe
     * @dev Grants/revokes admin privileges to specified addresses for a particular safe
     * @param accounts Array of admin addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each admin
     * @custom:throws OnlyEtherFiSafe if called by any address other than a registered EtherFiSafe
     * @custom:throws InvalidInput if the admins array is empty or contains a zero address
     * @custom:throws ArrayLengthMismatch if the array lengths mismatch
     */
    function configureSafeAdmins(address[] calldata accounts, bool[] calldata shouldAdd) external;

    /**
     * @notice Verifies if an account has safe admin privileges
     * @param safe The address of the safe
     * @param account The address to check for safe admin role
     * @custom:throws OnlySafeAdmin if the account does not have the SafeAdmin role
     */
    function onlySafeAdmin(address safe, address account) external view;

    /**
     * @notice Returns if an account has safe admin privileges
     * @param safe The address of the safe
     * @param account The address to check for safe admin role
     * @return bool suggesting if the account has the safe admin role
     */
    function isSafeAdmin(address safe, address account) external view returns (bool);

    /**
     * @notice Retrieves all addresses that have the safe admin role for a particular safe
     * @param safe The address of the safe
     * @return Array of addresses that have the safe admin role
     */
    function getSafeAdmins(address safe) external view returns (address[] memory);
}
