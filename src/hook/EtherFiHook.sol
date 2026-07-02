// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { ICashModule } from "../interfaces/ICashModule.sol";
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
    /// @notice The lowest Aave health factor (1e18 scale) a non-cash module operation may leave a safe at
    uint256 public immutable minHealthFactor;

    /// @notice Thrown when a non-admin address attempts to perform an admin-only operation
    error OnlyAdmin();
    /// @notice Thrown when input parameters are invalid or zero address is provided
    error InvalidInput();
    /// @notice Thrown when the completed operation would leave the safe below minHealthFactor
    error OperationBreachesHealth();

    constructor(address _dataProvider, uint256 _minHealthFactor) payable {
        dataProvider = IEtherFiDataProvider(_dataProvider);
        minHealthFactor = _minHealthFactor;
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
     * @dev Reverts if the safe's Aave health factor is below minHealthFactor. CashModule operations are
     *      skipped: they guard themselves via the gateway, and repay from an unhealthy state must not revert.
     * @param module Address of the module being operated on
     */
    function postOpHook(address module) external view {
        ICashModule cashModule = ICashModule(dataProvider.getCashModule());
        if (module == address(cashModule)) return;

        if (cashModule.getGateway().getAccountData(msg.sender).healthFactor < minHealthFactor) revert OperationBreachesHealth();
    }
}