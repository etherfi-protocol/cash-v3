// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import {IEtherFiSafeFactory} from "../interfaces/IEtherFiSafeFactory.sol";

/**
 * @title EtherFiDataProvider
 * @author ether.fi
 * @notice Stores important parameters and data for the ether.fi protocol
 * @dev Implements upgradeable proxy pattern and role-based access control
 */
contract EtherFiDataProvider is UpgradeableProxy {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /// @custom:storage-location erc7201:etherfi.storage.EtherFiDataProvider
    struct EtherFiDataProviderStorage {
        /// @notice Set containing addresses of all the whitelisted modules
        EnumerableSetLib.AddressSet whitelistedModules;
        /// @notice Address of the Cash Module
        address cashModule;
        /// @notice Address of the hook contract
        address hook;
        /// @notice Instance of the Safe factory
        IEtherFiSafeFactory etherFiSafeFactory;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiDataProvider")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiDataProviderStorageLocation = 0xb3086c0036ec0314dd613f04f2c0b41c0567e73b5b69f0a0d6acdbce48020e00;

    /// @notice Role identifier for administrative privileges
    bytes32 public constant DATA_PROVIDER_ADMIN_ROLE = keccak256("DATA_PROVIDER_ADMIN_ROLE");

    /// @notice Thrown when input parameters are invalid or zero address is provided
    error InvalidInput();
    /// @notice Thrown when array lengths don't match in configuration functions
    error ArrayLengthMismatch();
    /// @notice Thrown when an invalid module address is provided at the specified index
    /// @param index The index where the invalid module was found
    error InvalidModule(uint256 index);
    /// @notice Thrown when an invalid Cash module address is provided
    error InvalidCashModule();
    /// @notice Thrown when a non-admin address attempts to perform an admin-only operation
    error OnlyAdmin();
    /// @notice Throws when trying to reinit the modules
    error ModulesAlreadySetup();

    /// @notice Emitted when modules are configured or their whitelist status changes
    /// @param modules Array of module addresses that were configured
    /// @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
    event ModulesConfigured(address[] modules, bool[] shouldWhitelist);

    /// @notice Emitted when modules are setup initially
    /// @param modules Array of module addresses that were whitelisted
    event ModulesSetup(address[] modules);

    /// @notice Emitted when Cash module is configured
    /// @param oldCashModule Address of old Cash Module
    /// @param newCashModule Address of new Cash Module
    event CashModuleConfigured(address oldCashModule, address newCashModule);
    
    /// @notice Emitted when EtherFiSafeFactory is configured
    /// @param oldFactory Address of old factory
    /// @param newFactory Address of new factory
    event EtherFiSafeFactoryConfigured(address oldFactory, address newFactory);

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
     * @param _hook Address of the initial hook contract
     */
    function initialize(address _roleRegistry, address _cashModule, address[] calldata _modules, address _hook, address _etherFiSafeFactory) external initializer {
        __UpgradeableProxy_init(_roleRegistry);

        _setupModules(_modules);
        
        if (_etherFiSafeFactory == address(0)) revert InvalidInput();
        _setEtherFiSafeFactory(_etherFiSafeFactory);
        // The condition applies because the Hook might be present only on specific chains
        if (_hook != address(0)) _setHookAddress(_hook);
        // The condition applies because the Cash Module might be present only on specific chains
        if (_cashModule != address(0)) _setCashModule(_cashModule);
    }

    /**
     * @notice Configures multiple modules' whitelist status
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
     */
    function configureModules(address[] calldata modules, bool[] calldata shouldWhitelist) external {
        _onlyDataProviderAdmin();
        _configureModules(modules, shouldWhitelist);
    }

    /**
     * @notice Updates the hook address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param hook New hook address to set
     */
    function setHookAddress(address hook) external {
        _onlyDataProviderAdmin();
        _setHookAddress(hook);
    }

    /**
     * @notice Updates the etherFiSafeFactory instance address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param factory New factory address to set
     */
    function setEtherFiSafeFactory(address factory) external {
        _onlyDataProviderAdmin();
        _setEtherFiSafeFactory(factory);
    }

    /**
     * @notice Updates the address of the Cash Module
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param cashModule New cash module address to set
     */
    function setCashModule(address cashModule) external {
        _onlyDataProviderAdmin();
        _setCashModule(cashModule);
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
     * @notice Returns the address of the Cash Module
     * @return Address of the cash module
     */
    function getCashModule() public view returns (address) {
        return _getEtherFiDataProviderStorage().cashModule;
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
        if (len > 1) modules.checkDuplicates();

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
     * @notice Sets up multiple modules initially
     * @param modules Array of module addresses to configure
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws InvalidModule If any module address is zero
     * @custom:throws UnsupportedModule If a module is not whitelisted on the data provider
     */
    function _setupModules(address[] calldata modules) internal {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();

        if ($.whitelistedModules.length() != 0) revert ModulesAlreadySetup();

        uint256 len = modules.length;
        if (modules.length == 0) revert InvalidInput();
        if (len > 1) modules.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (modules[i] == address(0)) revert InvalidModule(i);
            $.whitelistedModules.add(modules[i]);

            unchecked {
                ++i;
            }
        }

        emit ModulesSetup(modules);
    }

    /**
     * @dev Internal function to configure cash module
     * @param cashModule Cash module address
     */
    function _setCashModule(address cashModule) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();
        if (cashModule == address(0)) revert InvalidCashModule();

        emit CashModuleConfigured($.cashModule, cashModule);
        $.cashModule = cashModule;
    }

    /**
     * @dev Internal function to configure EtherFiSafeFactory address
     * @param etherFiSafeFactory EtherFiSafeFactory address
     */
    function _setEtherFiSafeFactory(address etherFiSafeFactory) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();
        if (etherFiSafeFactory == address(0)) revert InvalidInput();

        emit EtherFiSafeFactoryConfigured(address($.etherFiSafeFactory), etherFiSafeFactory);
        $.etherFiSafeFactory = IEtherFiSafeFactory(etherFiSafeFactory);
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
    function _onlyDataProviderAdmin() private view {
        if (!roleRegistry().hasRole(DATA_PROVIDER_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }
}
