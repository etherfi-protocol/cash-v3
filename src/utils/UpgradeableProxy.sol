// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";

/**
 * @title UpgradeableProxy
 * @author ether.fi
 * @notice An UpgradeableProxy contract which can be upgraded by RoleRegistry contract
 */
contract UpgradeableProxy is UUPSUpgradeable, PausableUpgradeable, ReentrancyGuardTransientUpgradeable {
    /// @custom:storage-location erc7201:etherfi.storage.UpgradeableProxy
    struct UpgradeableProxyStorage {
        /// @notice Reference to the role registry contract for access control
        IRoleRegistry roleRegistry;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.UpgradeableProxy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant UpgradeableProxyStorageLocation = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    /// @notice Error thrown when caller is unauthorized to perform an operation
    error Unauthorized();

    /// @notice Error thrown when caller is not the role registry owner
    error OnlyRoleRegistryOwner();


    /**
     * @notice Returns the address of the Role Registry contract
     * @return roleRegistry Reference to the role registry contract
     */
    function roleRegistry() public view returns (IRoleRegistry) {
        UpgradeableProxyStorage storage $ = _getUpgradeableProxyStorage();
        return $.roleRegistry;
    }

    /**
     * @dev Initializes the contract with Role Registry
     * @param _roleRegistry Address of the role registry contract
     */
    function __UpgradeableProxy_init(address _roleRegistry) internal onlyInitializing {
        UpgradeableProxyStorage storage $ = _getUpgradeableProxyStorage();
        $.roleRegistry = IRoleRegistry(_roleRegistry);

        __ReentrancyGuardTransient_init();
        __Pausable_init_unchained();
    }

    /**
     * @dev Returns the storage struct from the specified storage slot
     * @return $ Reference to the UpgradeableProxyStorage struct
     */
    function _getUpgradeableProxyStorage() internal pure returns (UpgradeableProxyStorage storage $) {
        assembly {
            $.slot := UpgradeableProxyStorageLocation
        }
    }

    /**
     * @dev Updates the role registry contract address
     * @param _roleRegistry The address of the new role registry contract
     * @custom:security This is a critical function that updates access control
     */
    function _setRoleRegistry(address _roleRegistry) internal {
        UpgradeableProxyStorage storage $ = _getUpgradeableProxyStorage();
        $.roleRegistry = IRoleRegistry(_roleRegistry);
    }

    /**
     * @dev Ensures only authorized upgraders can upgrade the contract
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        UpgradeableProxyStorage storage $ = _getUpgradeableProxyStorage();
        $.roleRegistry.onlyUpgrader(msg.sender);

        // Silence compiler warning on unused variables.
        newImplementation = newImplementation;
    }

    /**
     * @notice Pauses the contract
     * @dev Only callable by accounts with the pauser role
     */
    function pause() external {
        roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /**
     * @notice Unpauses the contract
     * @dev Only callable by accounts with the unpauser role
     */
    function unpause() external {
        roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    /**
     * @dev Modifier to restrict access to specific roles
     * @param role Role identifier
     */
    modifier onlyRole(bytes32 role) {
        if (!roleRegistry().hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    /**
     * @dev Modifier to restrict access to owner of the role registry
     */
    modifier onlyRoleRegistryOwner() {
        if (roleRegistry().owner() != msg.sender) revert OnlyRoleRegistryOwner();
        _;
    }
}
