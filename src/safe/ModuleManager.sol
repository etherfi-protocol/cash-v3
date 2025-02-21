// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";

/**
 * @title ModuleManager
 * @notice Manages the addition and removal of modules for the EtherFi Safe
 * @author ether.fi
 * @dev Abstract contract that handles module management functionality
 *      Uses ERC-7201 for namespace storage pattern
 */
abstract contract ModuleManager is EtherFiSafeErrors {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

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
     * @notice Configures multiple modules at once
     * @param _modules Array of module addresses to configure
     * @param _shouldWhitelist Array of booleans indicating whether to add (true) or remove (false) each module
     * @dev Efficiently handles multiple module operations in a single transaction
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws ArrayLengthMismatch If modules and shouldWhitelist arrays have different lengths
     * @custom:throws InvalidModule If any module address is zero
     */
    function _configureModules(address[] calldata _modules, bool[] calldata _shouldWhitelist) internal {
        ModuleManagerStorage storage $ = _getModuleManagerStorage();

        uint256 len = _modules.length;
        if (len == 0) revert InvalidInput();
        if (len != _shouldWhitelist.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            if (_modules[i] == address(0)) revert InvalidModule(i);

            if (_shouldWhitelist[i] && !$.modules.contains(_modules[i])) $.modules.add(_modules[i]);
            if (!_shouldWhitelist[i] && $.modules.contains(_modules[i])) $.modules.remove(_modules[i]);

            unchecked { ++i; }
        }

        emit ModulesConfigured(_modules, _shouldWhitelist);
    }

    /**
     * @notice Checks if an address is a whitelisted module
     * @param module Address to check
     * @return bool True if the address is a whitelisted module, false otherwise
     * @dev Uses EnumerableSet for efficient O(1) lookup
     */
    function isModule(address module) public view returns (bool) {
        return _getModuleManagerStorage().modules.contains(module);
    }

    /**
     * @notice Returns all whitelisted modules
     * @return address[] Array containing all whitelisted module addresses
     * @dev Uses EnumerableSet's values function to get all elements
     */
    function getModules() public view returns (address[] memory) {
        return _getModuleManagerStorage().modules.values();
    }
}
