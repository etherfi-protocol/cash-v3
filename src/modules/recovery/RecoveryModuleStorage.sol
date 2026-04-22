// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IRecoveryModule } from "../../interfaces/IRecoveryModule.sol";

/**
 * @title RecoveryModuleStorage
 * @author ether.fi
 * @notice ERC-7201 namespaced storage for the RecoveryModule
 * @dev Matches the pattern used by ModuleBase and UpgradeableProxy in this repo
 */
abstract contract RecoveryModuleStorage {
    /// @custom:storage-location erc7201:etherfi.storage.RecoveryModule
    struct RecoveryModuleStorageStruct {
        /// @notice Pending recoveries keyed by (safe, id)
        mapping(address safe => mapping(bytes32 id => IRecoveryModule.PendingRecovery)) pending;
        /// @notice Per-safe monotonic nonce used to derive recovery ids
        mapping(address safe => uint256) recoveryNonce;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.RecoveryModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RecoveryModuleStorageLocation = 0xe4cf8cb8aef97d994422d78cbdbe465a9f990b3d94e574e9e3fc4468f8437000;

    /**
     * @dev Returns the storage struct from the specified storage slot
     * @return $ Reference to the RecoveryModuleStorageStruct
     */
    function _recoveryStorage() internal pure returns (RecoveryModuleStorageStruct storage $) {
        assembly {
            $.slot := RecoveryModuleStorageLocation
        }
    }
}
