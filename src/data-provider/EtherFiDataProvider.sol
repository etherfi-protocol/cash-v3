// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title EtherFiDataProvider
 * @author ether.fi
 * @notice Stores important parameters and data for the ether.fi protocol
 * @dev Implements upgradeable proxy pattern and role-based access control
 */
contract EtherFiDataProvider is UpgradeableProxy {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.EtherFiDataProvider
    struct EtherFiDataProviderStorage {
        /// @notice Set containing addresses of all the whitelisted modules
        EnumerableSetLib.AddressSet whitelistedModules;
        /// @notice Address of the hook contract
        address hook;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiDataProvider")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiDataProviderStorageLocation = 0xb3086c0036ec0314dd613f04f2c0b41c0567e73b5b69f0a0d6acdbce48020e00;

    /// @notice Role identifier for administrative privileges
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Thrown when input parameters are invalid or zero address is provided
    error InvalidInput();
    /// @notice Thrown when array lengths don't match in configuration functions
    error ArrayLengthMismatch();
    /// @notice Thrown when an invalid module address is provided at the specified index
    /// @param index The index where the invalid module was found
    error InvalidModule(uint256 index);
    /// @notice Thrown when a non-admin address attempts to perform an admin-only operation
    error OnlyAdmin();

    /// @notice Emitted when modules are configured or their whitelist status changes
    /// @param modules Array of module addresses that were configured
    /// @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
    event ModulesConfigured(address[] modules, bool[] shouldWhitelist);

    /// @notice Emitted when the hook address is updated
    /// @param oldHookAddress Previous hook address
    /// @param newHookAddress New hook address
    event HookAddressUpdated(address oldHookAddress, address newHookAddress);

    /**
     * @dev Internal function to access the contract's storage
     * @return $ Storage pointer to the EtherFiDataProviderStorage struct
     */
    function _getEtherFiDataProviderStorage() internal pure returns (EtherFiDataProviderStorage storage $) {
        assembly {
            $.slot := EtherFiDataProviderStorageLocation
        }
    }

    /**
     * @notice Initializes the contract with initial modules and hook address
     * @dev Can only be called once due to initializer modifier
     * @param _roleRegistry Address of the role registry contract
     * @param _modules Array of initial module addresses to configure
     * @param _shouldWhitelist Array of boolean values indicating which modules to whitelist
     * @param _hook Address of the initial hook contract
     */
    function initialize(address _roleRegistry, address[] calldata _modules, bool[] calldata _shouldWhitelist, address _hook) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        _configureModules(_modules, _shouldWhitelist);
        _setHookAddress(_hook);
    }

    /**
     * @notice Configures multiple modules' whitelist status
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
     */
    function configureModules(address[] calldata modules, bool[] calldata shouldWhitelist) external {
        _onlyAdmin();
        _configureModules(modules, shouldWhitelist);
    }

    /**
     * @notice Updates the hook address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param hook New hook address to set
     */
    function setHookAddress(address hook) external {
        _onlyAdmin();
        _setHookAddress(hook);
    }

    /**
     * @notice Checks if a module address is whitelisted
     * @param module Address to check
     * @return bool True if the module is whitelisted, false otherwise
     */
    function isWhitelistedModule(address module) public view returns (bool) {
        return _getEtherFiDataProviderStorage().whitelistedModules.contains(module);
    }

    /**
     * @notice Retrieves all whitelisted module addresses
     * @return address[] Array of whitelisted module addresses
     */
    function getWhitelistedModules() public view returns (address[] memory) {
        return _getEtherFiDataProviderStorage().whitelistedModules.values();
    }

    /**
     * @notice Returns the current hook address
     * @return address Current hook address
     */
    function getHookAddress() public view returns (address) {
        return _getEtherFiDataProviderStorage().hook;
    }

    /**
     * @dev Internal function to configure modules' whitelist status
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
     */
    function _configureModules(address[] calldata modules, bool[] calldata shouldWhitelist) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();

        uint256 len = modules.length;
        if (len == 0) revert InvalidInput();
        if (len != shouldWhitelist.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            if (modules[i] == address(0)) revert InvalidModule(i);

            if (shouldWhitelist[i] && !$.whitelistedModules.contains(modules[i])) $.whitelistedModules.add(modules[i]);
            if (!shouldWhitelist[i] && $.whitelistedModules.contains(modules[i])) $.whitelistedModules.remove(modules[i]);

            unchecked {
                ++i;
            }
        }

        emit ModulesConfigured(modules, shouldWhitelist);
    }

    /**
     * @dev Internal function to update the hook address
     * @param hook New hook address to set
     */
    function _setHookAddress(address hook) private {
        if (hook == address(0)) revert InvalidInput();
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();

        emit HookAddressUpdated($.hook, hook);
        $.hook = hook;
    }

    /**
     * @dev Internal function to verify caller has admin role
     */
    function _onlyAdmin() private view {
        if (!roleRegistry().hasRole(ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }
}
