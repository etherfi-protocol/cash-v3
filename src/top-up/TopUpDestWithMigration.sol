// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TopUpDest } from "./TopUpDest.sol";

/**
 * @title TopUpDestWithMigration
 * @notice Extends TopUpDest with migration support - blocks top-ups to migrated safes
 * @dev Upgrade the existing TopUpDest proxy to this impl to enable migration blocking.
 *      Uses a separate ERC-7201 storage slot so it doesn't conflict with TopUpDest storage.
 *      setMigrated is called by the MigrationBridgeModule during bridgeAll().
 * @author ether.fi
 */
contract TopUpDestWithMigration is TopUpDest {
    /// @custom:storage-location erc7201:etherfi.storage.TopUpDestWithMigration
    struct TopUpDestWithMigrationStorage {
        mapping(address safe => bool migrated) migratedSafes;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TopUpDestWithMigration")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TopUpDestWithMigrationStorageLocation =
        0x90fe676a7811a6beb9a3c80c914a174465fa250666bfd35cffee4ebbe32c2c00;

    /// @notice The migration module address authorized to mark safes as migrated
    address public immutable migrationModule;

    /// @notice Error thrown when top-up is attempted for a migrated safe
    error SafeMigrated();

    /// @notice Error thrown when caller is not the migration module
    error OnlyMigrationModule();

    /// @notice Emitted when a safe's migration status is updated
    event SafeMigrationSet(address indexed safe, bool migrated);

    constructor(address _etherFiDataProvider, address _weth, address _migrationModule) TopUpDest(_etherFiDataProvider, _weth) {
        migrationModule = _migrationModule;
    }

    function _getTopUpDestWithMigrationStorage() internal pure returns (TopUpDestWithMigrationStorage storage $) {
        assembly {
            $.slot := TopUpDestWithMigrationStorageLocation
        }
    }

    /**
     * @notice Marks safes as migrated, blocking future top-ups
     * @dev Only callable by the migration module
     * @param safes Array of safe addresses to mark as migrated
     */
    function setMigrated(address[] calldata safes) external {
        if (msg.sender != migrationModule) revert OnlyMigrationModule();
        TopUpDestWithMigrationStorage storage $ = _getTopUpDestWithMigrationStorage();
        for (uint256 i = 0; i < safes.length;) {
            if (!etherFiDataProvider.isEtherFiSafe(safes[i])) revert NotARegisteredSafe();
            if ($.migratedSafes[safes[i]]) {
                unchecked { ++i; }
                continue;
            }
            $.migratedSafes[safes[i]] = true;
            emit SafeMigrationSet(safes[i], true);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Unmarks safes as migrated, re-enabling top-ups
     * @dev Only callable by the RoleRegistry owner
     * @param safes Array of safe addresses to unmark
     */
    function unsetMigrated(address[] calldata safes) external onlyRoleRegistryOwner {
        TopUpDestWithMigrationStorage storage $ = _getTopUpDestWithMigrationStorage();
        for (uint256 i = 0; i < safes.length;) {
            $.migratedSafes[safes[i]] = false;
            emit SafeMigrationSet(safes[i], false);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Checks if a safe has been migrated
     * @param safe Address of the safe to check
     * @return True if the safe is migrated and top-ups are blocked
     */
    function isMigrated(address safe) external view returns (bool) {
        return _getTopUpDestWithMigrationStorage().migratedSafes[safe];
    }

    /**
     * @notice Overrides _topUp to block top-ups to migrated safes
     */
    function _topUp(bytes32 txHash, address user, uint256 chainId, address token, uint256 amount) internal override {
        if (_getTopUpDestWithMigrationStorage().migratedSafes[user]) revert SafeMigrated();
        super._topUp(txHash, user, chainId, token, amount);
    }
}
