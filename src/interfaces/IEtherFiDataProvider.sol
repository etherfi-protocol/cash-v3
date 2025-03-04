// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IRoleRegistry } from "./IRoleRegistry.sol";

/**
 * @title IEtherFiDataProvider
 * @author ether.fi
 * @notice Interface for the EtherFiDataProvider contract that manages important data for ether.fi
 */
interface IEtherFiDataProvider {
    /**
     * @notice Configures multiple modules' whitelist status
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
     */
    function configureModules(address[] calldata modules, bool[] calldata shouldWhitelist) external;

    /**
     * @notice Updates the hook address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param hook New hook address to set
     */
    function setHookAddress(address hook) external;

    /**
     * @notice Updates the address of the Cash Module
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param cashModule New cash module address to set
     */
    function setCashModule(address cashModule) external;

    /**
     * @notice Checks if a module address is whitelisted
     * @param module Address to check
     * @return bool True if the module is whitelisted, false otherwise
     */
    function isWhitelistedModule(address module) external view returns (bool);

    /**
     * @notice Retrieves all whitelisted module addresses
     * @return address[] Array of whitelisted module addresses
     */
    function getWhitelistedModules() external view returns (address[] memory);

    /**
     * @notice Returns the address of the Cash Module
     * @return Address of the cash module
     */
    function getCashModule() external view returns (address);

    /**
     * @notice Returns the address of the Cash Lens contract
     * @return Address of the Cash Lens contract
     */
    function getCashLens() external view returns (address);

    /**
     * @notice Returns the address of the Price provider contract
     * @return Address of the Price provider contract
     */
    function getPriceProvider() external view returns (address);

    /**
     * @notice Returns the current hook address
     * @return address Current hook address
     */
    function getHookAddress() external view returns (address);

    function getEtherFiSafeFactory() external view returns (address);

    /**
     * @notice Function to check if an account is an EtherFiSafe
     * @param account Address of the account to check
     */
    function isEtherFiSafe(address account) external view returns (bool);

    /**
     * @notice Role identifier for administrative privileges
     * @return bytes32 The keccak256 hash of "ADMIN_ROLE"
     */
    function ADMIN_ROLE() external view returns (bytes32);

    /**
     * @notice Returns the address of the Role Registry contract
     * @return roleRegistry Reference to the role registry contract
     */
    function roleRegistry() external view returns (IRoleRegistry);
}
