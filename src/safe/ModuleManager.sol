// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IModule } from "../interfaces/IModule.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";

/**
 * @title ModuleManager
 * @notice Manages the addition and removal of modules for the EtherFi Safe
 * @author ether.fi
 * @dev Abstract contract that handles module management functionality
 */
abstract contract ModuleManager is EtherFiSafeBase {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /// @custom:storage-location erc7201:etherfi.storage.ModuleManager
    struct ModuleManagerStorage {
        /// @notice Set containing addresses of all the attached modules
        EnumerableSetLib.AddressSet modules;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.ModuleManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ModuleManagerStorageLocation = 0x6f297332685baf3d7ed2366c1e1996176ab52e89e9bd6ee3d882f5057ea1bd00;

    /// @notice Emitted when modules are configured
    /// @param modules Array of module addresses that were configured
    /// @param shouldWhitelist Array indicating whether each module was added or removed
    event ModulesConfigured(address[] modules, bool[] shouldWhitelist);

    /// @notice Emitted when modules are setup initially
    /// @param modules Array of module addresses that were setup
    event ModulesSetup(address[] modules);

    /**
     * @dev Returns the storage struct for ModuleManager
     * @return $ Reference to the ModuleManagerStorage struct
     * @custom:storage-location Uses ERC-7201 namespace storage pattern
     */
    function _getModuleManagerStorage() internal pure returns (ModuleManagerStorage storage $) {
        assembly {
            $.slot := ModuleManagerStorageLocation
        }
    }

    /**
     * @notice Sets up multiple modules initially
     * @param _modules Array of module addresses to configure
     * @param _moduleSetupData Array of data for setting up individual modules for the safe
     * @custom:throws ModulesAlreadySetup If the module manager is already setup
     * @custom:throws ArrayLengthMismatch If the arrays have a length mismatch
     * @custom:throws DuplicateElementFound If the module addresses are repeated in the array
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws InvalidModule If any module address is zero
     * @custom:throws UnsupportedModule If a module is not whitelisted on the data provider
     */
    function _setupModules(address[] calldata _modules, bytes[] calldata _moduleSetupData) internal {
        ModuleManagerStorage storage $ = _getModuleManagerStorage();

        if ($.modules.length() != 0) revert ModulesAlreadySetup();

        uint256 len = _modules.length;
        if (len == 0) revert InvalidInput();
        if (len != _moduleSetupData.length) revert ArrayLengthMismatch();
        if (len > 1) _modules.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (_modules[i] == address(0)) revert InvalidModule(i);
            (bool isWhitelisteModuleOnDataProvider, ) = _isWhitelistedOnDataProvider(_modules[i]);
            if (!isWhitelisteModuleOnDataProvider) revert UnsupportedModule(i);
            
            $.modules.add(_modules[i]);
            IModule(_modules[i]).setupModule(_moduleSetupData[i]);

            unchecked {
                ++i;
            }
        }

        emit ModulesSetup(_modules);
    }

    /**
     * @notice Configures module whitelist with signature verification
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of booleans indicating whether to add or remove each module
     * @param moduleSetupData Array of data for setting up individual modules for the safe
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws ArrayLengthMismatch If modules and shouldWhitelist arrays have different lengths
     * @custom:throws InvalidModule If any module address is zero
     * @custom:throws InvalidSignatures If the signature verification fails
     * @custom:throws DuplicateElementFound If the module addresses are repeated in the array
     */
    function configureModules(address[] calldata modules, bool[] calldata shouldWhitelist, bytes[] calldata moduleSetupData, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        
        // Hash each bytes element in moduleSetupData individually
        uint256 len = moduleSetupData.length;
        bytes32[] memory dataHashes = new bytes32[](len);
        for (uint256 i = 0; i < len; ) {
            dataHashes[i] = keccak256(moduleSetupData[i]);
            unchecked {
                ++i;
            }
        }
        
        // Concatenate the hashes and hash again
        bytes32 moduleSetupDataHash = keccak256(abi.encodePacked(dataHashes));
        
        // Use the correct hash in the struct hash calculation
        bytes32 structHash = keccak256(abi.encode(
            CONFIGURE_MODULES_TYPEHASH,
            keccak256(abi.encodePacked(modules)),
            keccak256(abi.encodePacked(shouldWhitelist)),
            moduleSetupDataHash,
            _useNonce()
        ));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _configureModules(modules, shouldWhitelist, moduleSetupData);
    }


    /**
     * @notice Configures multiple modules at once
     * @param _modules Array of module addresses to configure
     * @param _shouldWhitelist Array of booleans indicating whether to add (true) or remove (false) each module
     * @param _moduleSetupData Array of data for setting up individual modules for the safe
     * @dev Efficiently handles multiple module operations in a single transaction
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws ArrayLengthMismatch If modules and shouldWhitelist arrays have different lengths
     * @custom:throws InvalidModule If any module address is zero
     * @custom:throws UnsupportedModule If a module is not whitelisted on the data provider
     * @custom:throws DuplicateElementFound If the module addresses are repeated in the array
     */
    function _configureModules(address[] calldata _modules, bool[] calldata _shouldWhitelist, bytes[] calldata _moduleSetupData) internal {
        ModuleManagerStorage storage $ = _getModuleManagerStorage();

        uint256 len = _modules.length;
        if (len == 0) revert InvalidInput();
        if (len != _shouldWhitelist.length || len != _moduleSetupData.length) revert ArrayLengthMismatch();
        if (len > 1) _modules.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (_modules[i] == address(0)) revert InvalidModule(i);

            if (_shouldWhitelist[i] && !$.modules.contains(_modules[i])) {
                (bool isWhitelisteModuleOnDataProvider, ) = _isWhitelistedOnDataProvider(_modules[i]);
                if (!isWhitelisteModuleOnDataProvider) revert UnsupportedModule(i);
                $.modules.add(_modules[i]);
                IModule(_modules[i]).setupModule(_moduleSetupData[i]);
            }

            if (!_shouldWhitelist[i] && $.modules.contains(_modules[i])) $.modules.remove(_modules[i]);

            unchecked {
                ++i;
            }
        }

        emit ModulesConfigured(_modules, _shouldWhitelist);
    }

    /**
     * @notice Checks if a module is whitelisted on the external data provider
     * @param module Address of the module to check
     * @return bool True if the module is whitelisted on the data provider
     * @return bool True if the module is a default module on the data provider
     */
    function _isWhitelistedOnDataProvider(address module) internal view virtual returns (bool, bool);

    /**
     * @notice Checks if an address is a valid whitelisted module
     * @param module Address to check
     * @return bool True if the address is a whitelisted module, false otherwise
     * @dev A module is considered valid if:
     *      1. It is a default module (these are always valid), or
     *      2. It is whitelisted on the data provider AND in the local modules set
     */
    function isModuleEnabled(address module) public view returns (bool) {
        (bool isWhitelistedModuleOnDataProvider, bool isDefaultModuleOnDataProvider) = _isWhitelistedOnDataProvider(module);
        if (isDefaultModuleOnDataProvider) return true;
        return isWhitelistedModuleOnDataProvider && _getModuleManagerStorage().modules.contains(module);
    }

    /**
     * @notice Returns all locally whitelisted modules
     * @return address[] Array containing all whitelisted module addresses
     * Note: This may not include default module if it's not explicitly added to storage
     */
    function getModules() public view returns (address[] memory) {
        return _getModuleManagerStorage().modules.values();
    }
}
