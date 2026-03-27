// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { ICashModule } from "../interfaces/ICashModule.sol";
import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title EtherFiHook
 * @author ether.fi
 * @notice Contract that implements pre and post operation hooks for the ether.fi protocol
 * @dev Implements upgradeable proxy pattern and role-based access control
 */
contract EtherFiHook is UpgradeableProxy {
    /// @notice Interface to the data provider contract
    IEtherFiDataProvider public immutable dataProvider;

    /// @notice Address of the migration module (bypasses ensureHealth)
    address public migrationModule;

    /// @notice Emitted when migration module is set
    event MigrationModuleSet(address indexed module);

    /// @notice Thrown when a non-admin address attempts to perform an admin-only operation
    error OnlyAdmin();
    /// @notice Thrown when input parameters are invalid or zero address is provided
    error InvalidInput();

    constructor(address _dataProvider) payable {
        dataProvider = IEtherFiDataProvider(_dataProvider);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with initial the EtherFiHook
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Hook called before module operations
     * @dev Currently implemented as a view function with no effects
     * @param module Address of the module being operated on
     */
    function preOpHook(address module) external view { }

    /**
     * @notice Hook called after module operations
     * @dev Currently implemented as a view function with no effects
     * @param module Address of the module being operated on
     */
    function postOpHook(address module) external view {
        ICashModule cashModule = ICashModule(dataProvider.getCashModule());
        if (module == address(cashModule)) return;

        // Migration module bypasses debt check — users must be able to bridge
        // collateral out even when they have outstanding debt
        if (module == migrationModule) return;

        IDebtManager debtManager = cashModule.getDebtManager();
        debtManager.ensureHealth(msg.sender);
    }

    /**
     * @notice Sets the migration module address that bypasses health checks
     * @param _migrationModule Address of the MigrationBridgeModule
     */
    function setMigrationModule(address _migrationModule) external {
        if (dataProvider.roleRegistry().owner() != msg.sender) revert OnlyAdmin();
        migrationModule = _migrationModule;
        emit MigrationModuleSet(_migrationModule);
    }
}
