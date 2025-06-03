// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IEtherFiSafeFactory } from "../interfaces/IEtherFiSafeFactory.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

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
        /// @notice Address of the Cash Lens contract
        address cashLens;
        /// @notice Address of the hook contract
        address hook;
        /// @notice Instance of the Safe factory
        IEtherFiSafeFactory etherFiSafeFactory;
        /// @notice Address of the price provider
        address priceProvider;
        /// @notice Address of the EtherFi Recovery Signer
        address etherFiRecoverySigner;
        /// @notice Address of the Third Party Recovery Signer
        address thirdPartyRecoverySigner;
        /// @notice Timelock for recovery
        uint256 recoveryDelayPeriod;
        /// @notice Default modules
        EnumerableSetLib.AddressSet defaultModules;
        /// @notice Address of the refund wallet 
        address refundWallet;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiDataProvider")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiDataProviderStorageLocation = 0xb3086c0036ec0314dd613f04f2c0b41c0567e73b5b69f0a0d6acdbce48020e00;

    /// @notice Role identifier for administrative privileges
    bytes32 public constant DATA_PROVIDER_ADMIN_ROLE = keccak256("DATA_PROVIDER_ADMIN_ROLE");

    /** 
     * @notice Struct for intiialize params
     * @param _roleRegistry Address of the role registry contract
     * @param _cashModule Address of the Cash Module contract
     * @param _cashLens Address of the Cash Lens contract
     * @param _modules Array of initial module addresses to configure
     * @param _defaultModules Array of initial default module addresses to configure
     * @param _hook Address of the initial hook contract
     * @param _etherFiRecoverySigner Address of the EtherFi Recovery Signer
     * @param _thirdPartyRecoverySigner Address of the Third Party Recovery Signer
     * @param _refundWallet Address of the Refund wallet
     */
    struct InitParams {
        address _roleRegistry;
        address _cashModule;
        address _cashLens;
        address[] _modules;
        address[] _defaultModules;
        address _hook;
        address _etherFiSafeFactory;
        address _priceProvider;
        address _etherFiRecoverySigner;
        address _thirdPartyRecoverySigner;
        address _refundWallet;
    }

    /// @notice Thrown when input parameters are invalid or zero address is provided
    error InvalidInput();
    /// @notice Thrown when array lengths don't match in configuration functions
    error ArrayLengthMismatch();
    /// @notice Thrown when an invalid module address is provided at the specified index
    /// @param index The index where the invalid module was found
    error InvalidModule(uint256 index);
    /// @notice Thrown when an invalid Cash module address is provided
    error InvalidCashModule();
    /// @notice Thrown when an invalid Cash lens address is provided
    error InvalidCashLens();
    /// @notice Thrown when a non-admin address attempts to perform an admin-only operation
    error OnlyAdmin();
    /// @notice Throws when trying to reinit the modules
    error ModulesAlreadySetup();

    /// @notice Emitted when modules are configured or their whitelist status changes
    /// @param modules Array of module addresses that were configured
    /// @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
    event ModulesConfigured(address[] modules, bool[] shouldWhitelist);

    /// @notice Emitted when default modules are configured or their whitelist status changes
    /// @param modules Array of default module addresses that were configured
    /// @param shouldWhitelist Array of boolean values indicating whether each module should be a whitelisted default module
    event DefaultModulesConfigured(address[] modules, bool[] shouldWhitelist);

    /// @notice Emitted when modules are setup initially
    /// @param modules Array of module addresses that were whitelisted
    event ModulesSetup(address[] modules);

    /// @notice Emitted when default modules are setup initially
    /// @param modules Array of default module addresses that were whitelisted
    event DefaultModulesSetup(address[] modules);

    /// @notice Emitted when Cash module is configured
    /// @param oldCashModule Address of old Cash Module
    /// @param newCashModule Address of new Cash Module
    event CashModuleConfigured(address oldCashModule, address newCashModule);

    /// @notice Emitted when Cash lens is configured
    /// @param oldCashLens Address of old Cash Lens
    /// @param newCashLens Address of new Cash Lens
    event CashLensConfigured(address oldCashLens, address newCashLens);

    /// @notice Emitted when EtherFiSafeFactory is configured
    /// @param oldFactory Address of old factory
    /// @param newFactory Address of new factory
    event EtherFiSafeFactoryConfigured(address oldFactory, address newFactory);

    /// @notice Emitted when EtherFiRecoverySigner is configured
    /// @param oldSigner Address of old signer
    /// @param newSigner Address of new signer
    event EtherFiRecoverySignerConfigured(address oldSigner, address newSigner);
    
    /// @notice Emitted when ThirdPartyRecoverySigner is configured
    /// @param oldSigner Address of old signer
    /// @param newSigner Address of new signer
    event ThirdPartyRecoverySignerConfigured(address oldSigner, address newSigner);
    
    /// @notice Emitted when Refund Wallet address is updated
    /// @param oldWallet Address of old wallet
    /// @param newWallet Address of new wallet
    event RefundWalletAddressUpdated(address oldWallet, address newWallet);

    /// @notice Emitted when the hook address is updated
    /// @param oldHookAddress Previous hook address
    /// @param newHookAddress New hook address
    event HookAddressUpdated(address oldHookAddress, address newHookAddress);

    /// @notice Emitted when the price provider is updated
    /// @param oldPriceProvider Previous price provider address
    /// @param newPriceProvider New price provider address
    event PriceProviderUpdated(address oldPriceProvider, address newPriceProvider);

    /// @notice Emitted when the recovery delay period is updated
    /// @param oldPeriod Old recovery delay period in seconds
    /// @param newPeriod New recovery delay period in seconds
    event RecoveryDelayPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    /**
     * @dev Internal function to access the contract's storage
     * @return $ Storage pointer to the EtherFiDataProviderStorage struct
     */
    function _getEtherFiDataProviderStorage() internal pure returns (EtherFiDataProviderStorage storage $) {
        assembly {
            $.slot := EtherFiDataProviderStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with initial modules and hook address
     * @dev Can only be called once due to initializer modifier
     * @param initParams Init params for initialize function
     */
    function initialize(InitParams calldata initParams) external initializer {
        __UpgradeableProxy_init(initParams._roleRegistry);
        _setupModules(initParams._modules);
        _setupDefaultModules(initParams._defaultModules);

        _setEtherFiSafeFactory(initParams._etherFiSafeFactory);
        _setPriceProvider(initParams._priceProvider);
        _setEtherFiRecoverySigner(initParams._etherFiRecoverySigner);
        _setThirdPartyRecoverySigner(initParams._thirdPartyRecoverySigner);
        _setRefundWallet(initParams._refundWallet);

        _getEtherFiDataProviderStorage().recoveryDelayPeriod = 3 days;

        // The condition applies because the Hook might be present only on specific chains
        if (initParams._hook != address(0)) _setHookAddress(initParams._hook);
        // The condition applies because the Cash Module might be present only on specific chains
        if (initParams._cashModule != address(0)) _setCashModule(initParams._cashModule);
        // The condition applies because the Cash Module might be present only on specific chains
        if (initParams._cashLens != address(0)) _setCashLens(initParams._cashLens);
    }

    /**
     * @notice Updates the address of the Cash Lens
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE
     * @param cashLens New cash lens address to set
     */
    function setCashLens(address cashLens) external {
        _onlyDataProviderAdmin();
        _setCashLens(cashLens);
    }

    /**
     * @notice Configures multiple modules' whitelist status
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
     */
    function configureModules(address[] calldata modules, bool[] calldata shouldWhitelist) external {
        _onlyDataProviderAdmin();
        _configureModules(modules, shouldWhitelist);
    }

    /**
     * @notice Configures multiple modules' whitelist status
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
     */
    function configureDefaultModules(address[] calldata modules, bool[] calldata shouldWhitelist) external {
        _onlyDataProviderAdmin();
        _configureDefaultModules(modules, shouldWhitelist);
    }

    /**
     * @notice Updates the address of the Price Provider
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE
     * @param _priceProvider New price provider address to set
     */
    function setPriceProvider(address _priceProvider) external {
        _onlyDataProviderAdmin();
        _setPriceProvider(_priceProvider);
    }

    /**
     * @notice Updates the hook address
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE
     * @param hook New hook address to set
     */
    function setHookAddress(address hook) external {
        _onlyDataProviderAdmin();
        _setHookAddress(hook);
    }

    /**
     * @notice Updates the etherFiSafeFactory instance address
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE
     * @param factory New factory address to set
     */
    function setEtherFiSafeFactory(address factory) external {
        _onlyDataProviderAdmin();
        _setEtherFiSafeFactory(factory);
    }

    /**
     * @notice Updates the EtherFi Recovery Signer address
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE    
     * @param signer Address of the new signer
     */
    function setEtherFiRecoverySigner(address signer) external {
        _onlyDataProviderAdmin();
        _setEtherFiRecoverySigner(signer);
    }

    /**
     * @notice Updates the EtherFi Recovery Signer address
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE    
     * @param signer Address of the new signer
     */
    function setThirdPartyRecoverySigner(address signer) external {
        _onlyDataProviderAdmin();
        _setThirdPartyRecoverySigner(signer);
    }

    /**
     * @notice Updates the EtherFi Refund Wallet address
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE    
     * @param wallet Address of the new wallet
     */
    function setRefundWallet(address wallet) external {
        _onlyDataProviderAdmin();
        _setRefundWallet(wallet);
    }

    /**
     * @notice Updates the Recovery delay period
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE    
     * @param period Recovery timelock period in seconds
     * @custom:throws InvalidInput when period is 0
     */
    function setRecoveryDelayPeriod(uint256 period) external {
        _onlyDataProviderAdmin();
        if (period == 0) revert InvalidInput();

        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();

        emit RecoveryDelayPeriodUpdated($.recoveryDelayPeriod, period);
        $.recoveryDelayPeriod = period;
    }

    /**
     * @notice Updates the address of the Cash Module
     * @dev Only callable by addresses with DATA_PROVIDER_ADMIN_ROLE
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
     * @notice Checks if a module address is a whitelisted default module
     * @param module Address to check
     * @return bool True if the module is a whitelisted default module, false otherwise
     */
    function isDefaultModule(address module) public view returns (bool) {
        return _getEtherFiDataProviderStorage().defaultModules.contains(module);
    }

    /**
     * @notice Retrieves all whitelisted module addresses
     * @return address[] Array of whitelisted module addresses
     */
    function getWhitelistedModules() public view returns (address[] memory) {
        return _getEtherFiDataProviderStorage().whitelistedModules.values();
    }

    /**
     * @notice Retrieves all default module addresses
     * @return address[] Array of default module addresses
     */
    function getDefaultModules() public view returns (address[] memory) {
        return _getEtherFiDataProviderStorage().defaultModules.values();
    }

    /**
     * @notice Returns the address of the Cash Module
     * @return Address of the Cash Module
     */
    function getCashModule() public view returns (address) {
        return _getEtherFiDataProviderStorage().cashModule;
    }

    /**
     * @notice Returns the address of the EtherFi Recovery signer
     * @return Address of the EtherFi Recovery Signer
     */
    function getEtherFiRecoverySigner() public view returns (address) {
        return _getEtherFiDataProviderStorage().etherFiRecoverySigner;
    }

    /**
     * @notice Returns the address of the Third Party Recovery signer
     * @return Address of the Third Party Recovery Signer
     */
    function getThirdPartyRecoverySigner() public view returns (address) {
        return _getEtherFiDataProviderStorage().thirdPartyRecoverySigner;
    }

    /**
     * @notice Returns the address of the Refund wallet
     * @return Address of the Refund wallet
     */
    function getRefundWallet() public view returns (address) {
        return _getEtherFiDataProviderStorage().refundWallet;
    }

    /**
     * @notice Returns the Recovery delay period in seconds
     * @return Recovery delay period in seconds
     */
    function getRecoveryDelayPeriod() public view returns (uint256) {
        return _getEtherFiDataProviderStorage().recoveryDelayPeriod;
    }

    /**
     * @notice Returns the address of the Cash Lens contract
     * @return Address of the Cash Lens contract
     */
    function getCashLens() public view returns (address) {
        return _getEtherFiDataProviderStorage().cashLens;
    }

    /**
     * @notice Returns the address of the Price Provider contract
     * @return Address of the Price Provider contract
     */
    function getPriceProvider() public view returns (address) {
        return _getEtherFiDataProviderStorage().priceProvider;
    }

    /**
     * @notice Returns the current hook address
     * @return address Current hook address
     */
    function getHookAddress() public view returns (address) {
        return _getEtherFiDataProviderStorage().hook;
    }

    /**
     * @notice Returns the EtherFiSafeFactory address
     * @return address EtherFiSafeFactory address
     */
    function getEtherFiSafeFactory() public view returns (address) {
        return address(_getEtherFiDataProviderStorage().etherFiSafeFactory);
    }

    /**
     * @notice Function to check if an account is an EtherFiSafe
     * @param account Address of the account to check
     */
    function isEtherFiSafe(address account) public view returns (bool) {
        return _getEtherFiDataProviderStorage().etherFiSafeFactory.isEtherFiSafe(account);
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
            if (!shouldWhitelist[i]){
                if ($.whitelistedModules.contains(modules[i])) $.whitelistedModules.remove(modules[i]);
                if ($.defaultModules.contains(modules[i])) $.defaultModules.remove(modules[i]);
            }

            unchecked {
                ++i;
            }
        }

        emit ModulesConfigured(modules, shouldWhitelist);
    }

    /**
     * @dev Internal function to configure default modules' whitelist status
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether each module should be whitelisted
     */
    function _configureDefaultModules(address[] calldata modules, bool[] calldata shouldWhitelist) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();

        uint256 len = modules.length;
        if (len == 0) revert InvalidInput();
        if (len != shouldWhitelist.length) revert ArrayLengthMismatch();
        if (len > 1) modules.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (modules[i] == address(0)) revert InvalidModule(i);

            if (shouldWhitelist[i]) {
                if (!$.whitelistedModules.contains(modules[i])) $.whitelistedModules.add(modules[i]);
                if (!$.defaultModules.contains(modules[i])) $.defaultModules.add(modules[i]);
            } 
            if (!shouldWhitelist[i] && $.defaultModules.contains(modules[i])) $.defaultModules.remove(modules[i]);
            

            unchecked {
                ++i;
            }
        }
        
        emit ModulesConfigured(modules, shouldWhitelist);
        emit DefaultModulesConfigured(modules, shouldWhitelist);
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
     * @notice Sets up multiple modules initially
     * @param modules Array of module addresses to configure
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws InvalidModule If any module address is zero
     * @custom:throws UnsupportedModule If a module is not whitelisted on the data provider
     */
    function _setupDefaultModules(address[] calldata modules) internal {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();

        if ($.defaultModules.length() != 0) revert ModulesAlreadySetup();

        uint256 len = modules.length;
        if (modules.length == 0) revert InvalidInput();
        if (len > 1) modules.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (modules[i] == address(0)) revert InvalidModule(i);
            $.defaultModules.add(modules[i]);
            if (!$.whitelistedModules.contains(modules[i])) $.whitelistedModules.add(modules[i]);

            unchecked {
                ++i;
            }
        }

        emit DefaultModulesSetup(modules);
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
     * @dev Internal function to configure cash lens
     * @param newCashLens Cash lens address
     */
    function _setCashLens(address newCashLens) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();
        if (newCashLens == address(0)) revert InvalidCashLens();

        emit CashLensConfigured($.cashLens, newCashLens);
        $.cashLens = newCashLens;
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
     * @dev Internal function to set EtherFi Recovery Signer address
     * @param etherFiRecoverySigner EtherFi Recovery Signer address
     */
    function _setEtherFiRecoverySigner(address etherFiRecoverySigner) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();
        if (etherFiRecoverySigner == address(0)) revert InvalidInput();

        emit EtherFiRecoverySignerConfigured(address($.etherFiRecoverySigner), etherFiRecoverySigner);
        $.etherFiRecoverySigner = etherFiRecoverySigner;
    }

    /**
     * @dev Internal function to set Third Party Recovery Signer address
     * @param thirdPartyRecoverySigner Third Party Recovery Signer address
     */
    function _setThirdPartyRecoverySigner(address thirdPartyRecoverySigner) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();
        if (thirdPartyRecoverySigner == address(0)) revert InvalidInput();

        emit ThirdPartyRecoverySignerConfigured(address($.thirdPartyRecoverySigner), thirdPartyRecoverySigner);
        $.thirdPartyRecoverySigner = thirdPartyRecoverySigner;
    }

    /**
     * @dev Internal function to set EtherFi Refund wallet address
     * @param wallet Refund wallet address
     */
    function _setRefundWallet(address wallet) private {
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();
        if (wallet == address(0)) revert InvalidInput();

        emit RefundWalletAddressUpdated(address($.refundWallet), wallet);
        $.refundWallet = wallet;
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
     * @dev Internal function to update the Price Provider address
     * @param _priceProvider New Price Provider address to set
     */
    function _setPriceProvider(address _priceProvider) private {
        if (_priceProvider == address(0)) revert InvalidInput();
        EtherFiDataProviderStorage storage $ = _getEtherFiDataProviderStorage();

        emit PriceProviderUpdated(address($.priceProvider), _priceProvider);
        $.priceProvider = _priceProvider;
    }

    /**
     * @dev Internal function to verify caller has admin role
     */
    function _onlyDataProviderAdmin() private view {
        if (!roleRegistry().hasRole(DATA_PROVIDER_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }
}
