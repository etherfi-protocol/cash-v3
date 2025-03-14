// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DebtManagerStorageContract, IEtherFiDataProvider } from "./DebtManagerStorageContract.sol";

/**
 * @title DebtManagerInitializer
 * @author ether.fi
 * @notice Initializer contract for the Debt Manager system
 * @dev This contract handles the initialization logic for DebtManagerStorageContract
 */
contract DebtManagerInitializer is DebtManagerStorageContract {
    /**
     * @dev Constructor that initializes the base DebtManagerStorageContract
     * @param dataProvider Address of the EtherFi data provider
     */
    constructor(address dataProvider) DebtManagerStorageContract(dataProvider) {}

    /**
     * @notice Initializes the DebtManager contract
     * @dev Sets up the role registry and initializes the reentrancy guard
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        __ReentrancyGuardTransient_init_unchained();
    }
}