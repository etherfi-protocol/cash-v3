// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableRoles } from "solady/auth/EnumerableRoles.sol";
import { Ownable } from "solady/auth/Ownable.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";

/**
 * @title RoleRegistry
 * @notice An upgradeable role-based access control system
 * @dev Implements UUPS upgradeability pattern and uses Solady's EnumerableRoles for efficient role management
 * @author ether.fi
 */
contract RoleRegistry is Ownable, UUPSUpgradeable, EnumerableRoles {
    /**
     * @notice Reference to the EtherFi data provider contract
     * @dev Used for validating Safe addresses and other protocol integrations
     */
    IEtherFiDataProvider public immutable etherFiDataProvider;

    /**
     * @notice Role identifier for pausing operations
     * @dev Used for emergency protocol pause functionality
     */
    bytes32 public constant PAUSER = keccak256("PAUSER");

    /**
     * @notice Role identifier for unpausing operations
     * @dev Used to resume protocol operations after a pause
     */
    bytes32 public constant UNPAUSER = keccak256("UNPAUSER");

    /**
     * @notice Role type for safe admin
     */
    bytes32 public constant SAFE_ADMIN_ROLE_TYPE = keccak256("SAFE_ADMIN_ROLE");

    /**
     * @notice Thrown when a non-owner attempts to upgrade the contract
     */
    error OnlyUpgrader();

    /**
     * @notice Thrown when an account without pauser role attempts to pause operations
     */
    error OnlyPauser();

    /**
     * @notice Thrown when an account without unpauser role attempts to unpause operations
     */
    error OnlyUnpauser();

    /**
     * @notice Thrown when an invalid input is passed as argument
     */
    error InvalidInput();

    /**
     * @notice Thrown when the account is not the safe admin for the particular safe
     */
    error OnlySafeAdmin();

    /**
     * @notice Thrown when array lengths mismatch
     */
    error ArrayLengthMismatch();

    /**
     * @notice Thrown when the caller is not an EtherFi Safe
     */
    error OnlyEtherFiSafe();

    /**
     * @notice Sets up the immutable state variables
     * @dev Disables initializers to prevent implementation contract initialization
     * @param _etherFiDataProvider Address of the EtherFi data provider contract
     * @custom:throws InvalidInput if the data provider address is zero
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _etherFiDataProvider) {
        _disableInitializers();

        if (_etherFiDataProvider == address(0)) revert InvalidInput();
        etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
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
     * @notice Generates a unique role identifier for safe administrators
     * @dev Creates a unique bytes32 identifier by hashing the safe address with a role type
     * @param safe The address of the safe for which to generate the admin role
     * @return bytes32 A unique role identifier for the specified safe's admins
     * @custom:throws InvalidInput if safe is a zero address
     */
    function getSafeAdminRole(address safe) public pure returns (bytes32) {
        if (safe == address(0)) revert InvalidInput();
        return keccak256(abi.encode(SAFE_ADMIN_ROLE_TYPE, safe));
    }

    /**
     * @notice Configures admin roles for a specific safe
     * @dev Grants/revokes admin privileges to specified addresses for a particular safe
     * @param accounts Array of admin addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each admin
     * @custom:throws EtherFiDataProvider.OnlyEtherFiSafe if called by any address other than a registered EtherFiSafe
     * @custom:throws InvalidInput if the admins array is empty or contains a zero address
     * @custom:throws ArrayLengthMismatch if the array lengths mismatch
     */
    function configureSafeAdmins(address[] calldata accounts, bool[] calldata shouldAdd) external {
        if (!etherFiDataProvider.isEtherFiSafe(msg.sender)) revert OnlyEtherFiSafe();

        bytes32 role = getSafeAdminRole(msg.sender);
        uint256 len = accounts.length;
        if (len == 0) revert InvalidInput();
        if (len != shouldAdd.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            if (accounts[i] == address(0)) revert InvalidInput();
            _setRole(accounts[i], uint256(role), shouldAdd[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Verifies if an account has safe admin privileges
     * @dev Reverts if the account does not have the SafeAdmin role
     * @param safe The address of the safe
     * @param account The address to check for safe admin role
     * @custom:throws OnlySafeAdmin if the account does not have the SafeAdmin role
     */
    function onlySafeAdmin(address safe, address account) external view {
        if (!hasRole(getSafeAdminRole(safe), account)) revert OnlySafeAdmin();
    }

    /**
     * @notice Returns if an account has safe admin privileges
     * @dev Non-reverting version of onlySafeAdmin
     * @param safe The address of the safe
     * @param account The address to check for safe admin role
     * @return bool True if the account has the safe admin role, false otherwise
     */
    function isSafeAdmin(address safe, address account) external view returns (bool) {
        return hasRole(getSafeAdminRole(safe), account);
    }

    /**
     * @notice Retrieves all addresses that have the safe admin role for a particular safe
     * @dev Uses the roleHolders function from EnumerableRoles
     * @param safe The address of the safe
     * @return Array of addresses that have the safe admin role
     */
    function getSafeAdmins(address safe) external view returns (address[] memory) {
        return roleHolders(getSafeAdminRole(safe));
    }

    /**
     * @notice Checks if an account has any of the specified roles
     * @dev Reverts if the account doesn't have at least one of the roles
     * @param account The address to check roles for
     * @param encodedRoles ABI encoded roles (abi.encode(ROLE_1, ROLE_2, ...))
     * @custom:throws EnumerableRolesUnauthorized if the account has none of the specified roles
     */
    function checkRoles(address account, bytes memory encodedRoles) external view {
        if (!_hasAnyRoles(account, encodedRoles)) __revertEnumerableRolesUnauthorized();
    }

    /**
     * @notice Checks if an account has a specific role
     * @dev Public view function for external role verification
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
    function roleHolders(bytes32 role) public view returns (address[] memory) {
        return roleHolders(uint256(role));
    }

    /**
     * @notice Verifies if an account has upgrader privileges
     * @dev Reverts if the account is not the owner
     * @param account The address to check for upgrader role
     * @custom:throws OnlyUpgrader if the account is not the contract owner
     */
    function onlyUpgrader(address account) external view {
        if (owner() != account) revert OnlyUpgrader();
    }

    /**
     * @notice Verifies if an account has pauser privileges
     * @dev Reverts if the account does not have the PAUSER role
     * @param account The address to check for pauser role
     * @custom:throws OnlyPauser if the account does not have the PAUSER role
     */
    function onlyPauser(address account) external view {
        if (!hasRole(PAUSER, account)) revert OnlyPauser();
    }

    /**
     * @notice Verifies if an account has unpauser privileges
     * @dev Reverts if the account does not have the UNPAUSER role
     * @param account The address to check for unpauser role
     * @custom:throws OnlyUnpauser if the account does not have the UNPAUSER role
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
     * @custom:throws Unauthorized if the caller is not the contract owner
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner { }
}
