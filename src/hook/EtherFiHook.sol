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
     * @dev CashModule runs its own health checks internally, so it is skipped here. Legacy safes are
     *      health-checked against DebtManager; gateway safes need no check (see inline note).
     * @param module Address of the module being operated on
     */
    function postOpHook(address module) external view {
        ICashModule cashModule = ICashModule(dataProvider.getCashModule());
        if (module == address(cashModule)) return;

        // Legacy safes: loose tokens are DebtManager collateral, so a module tx can move them out from
        // under the debt. This is the only guard, so it stays.
        // Gateway safes: no check needed. Supplied collateral lives inside Aave and only the gateway can
        // move it; Aave enforces healthFactor >= 1 (its single collateralFactor is the LTV) on every op
        // that can worsen health. Loose tokens are not Aave collateral, so a module tx cannot lower it.
        if (!cashModule.usesLendGateway(msg.sender)) cashModule.getDebtManager().ensureHealth(msg.sender);
    }
}