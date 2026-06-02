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

    /// @notice Module address that bypasses the post-op health check
    /// @dev AUDITOR CONTEXT: only set on Scroll, for the SCR recovery flow. SCR has
    ///      LTV = 0 (no borrow power), but pulling it triggers the post-op health check
    ///      which reverts on Scroll's now-stale collateral oracles. This lets that one
    ///      module skip the check. Defaults to address(0), so behaviour is unchanged on
    ///      every other chain/module.
    address public scrRecoveryModule;

    /// @notice Emitted when the SCR recovery module is set
    event ScrRecoveryModuleSet(address indexed module);

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

        // SCR recovery module bypasses the health check: SCR contributes no borrow
        // power (LTV = 0) and the recovery must not be blocked by stale Scroll oracles
        if (module == scrRecoveryModule) return;

        IDebtManager debtManager = cashModule.getDebtManager();
        debtManager.ensureHealth(msg.sender);
    }

    /**
     * @notice Sets the SCR recovery module address that bypasses the health check
     * @dev Only callable by the role registry owner
     * @param _scrRecoveryModule Address of the SCRRecoveryModule (or address(0) to clear)
     */
    function setScrRecoveryModule(address _scrRecoveryModule) external {
        if (dataProvider.roleRegistry().owner() != msg.sender) revert OnlyAdmin();
        scrRecoveryModule = _scrRecoveryModule;
        emit ScrRecoveryModuleSet(_scrRecoveryModule);
    }
}