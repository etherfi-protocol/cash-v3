// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableRoles } from "solady/auth/EnumerableRoles.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/**
 * @title RoleRegistry - An upgradeable role-based access control system
 * @author ether.fi
 * @notice Provides functionality for managing and querying roles with enumeration capabilities
 * @dev Implements UUPS upgradeability pattern and uses Solady's EnumerableRoles for efficient role management
 */
contract RoleRegistry is Ownable, UUPSUpgradeable, EnumerableRoles {
    /// @notice Role identifier for pausing cash-related operations
    bytes32 public constant PAUSER = keccak256("PAUSER");

    /// @notice Role identifier for unpausing cash-related operations
    bytes32 public constant UNPAUSER = keccak256("UNPAUSER");

    /// @notice Thrown when a non-owner attempts to upgrade the contract
    error OnlyUpgrader();
    error OnlyPauser();
    error OnlyUnpauser();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with an owner
     * @dev Sets up the initial owner and initializes upgradeability
     * @param _owner Address that will be granted ownership of the contract
     */
    function initialize(address _owner) external initializer {
        _initializeOwner(_owner);
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Checks if an account has any of the specified roles
     * @dev Reverts if the account doesn't have at least one of the roles
     * @param account The address to check roles for
     * @param encodedRoles ABI encoded roles (abi.encode(ROLE_1, ROLE_2, ...))
     */
    function checkRoles(address account, bytes memory encodedRoles) external view {
        if (!_hasAnyRoles(account, encodedRoles)) __revertEnumerableRolesUnauthorized();
    }

    /**
     * @notice Checks if an account has a specific role
     * @param role The role identifier to check
     * @param account The address to check the role for
     * @return bool True if the account has the role, false otherwise
     */
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return hasRole(account, uint256(role));
    }

    /**
     * @notice Grants a role to an account
     * @dev Only callable by the contract owner (handled in setRole function)
     * @param role The role identifier to grant
     * @param account The address to grant the role to
     */
    function grantRole(bytes32 role, address account) external {
        setRole(account, uint256(role), true);
    }

    /**
     * @notice Revokes a role from an account
     * @dev Only callable by the contract owner (handled in setRole function)
     * @param role The role identifier to revoke
     * @param account The address to revoke the role from
     */
    function revokeRole(bytes32 role, address account) external {
        setRole(account, uint256(role), false);
    }

    /**
     * @notice Gets all addresses that have a specific role
     * @dev Wrapper around EnumerableRoles roleHolders function converting bytes32 to uint256
     * @param role The role identifier to query
     * @return Array of addresses that have the specified role
     */
    function roleHolders(bytes32 role) external view returns (address[] memory) {
        return roleHolders(uint256(role));
    }

    /**
     * @notice Verifies if an account has upgrader privileges
     * @dev Reverts if the account is not the owner
     * @param account The address to check for upgrader role
     */
    function onlyUpgrader(address account) external view {
        if (owner() != account) revert OnlyUpgrader();
    }

    /**
     * @notice Verifies if an account has pauser privileges
     * @param account The address to check for pauser role
     */
    function onlyPauser(address account) external view {
        if (!hasRole(PAUSER, account)) revert OnlyPauser();
    }

    /**
     * @notice Verifies if an account has unpauser privileges
     * @param account The address to check for unpauser role
     */
    function onlyUnpauser(address account) external view {
        if (!hasRole(UNPAUSER, account)) revert OnlyUnpauser();
    }

    /**
     * @dev Internal function to revert with EnumerableRolesUnauthorized error
     * @custom:assembly Uses memory-safe assembly for gas optimization
     */
    function __revertEnumerableRolesUnauthorized() private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x99152cca) // `EnumerableRolesUnauthorized()`.
            revert(0x1c, 0x04)
        }
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner { }
}
