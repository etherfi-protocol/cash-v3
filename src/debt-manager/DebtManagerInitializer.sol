// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DebtManagerInitializer
 */
import { DebtManagerStorage, IEtherFiDataProvider } from "./DebtManagerStorage.sol";

contract DebtManagerInitializer is DebtManagerStorage {
    function initialize(address __owner, address __etherFiDataProvider) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init_unchained();
        __AccessControlDefaultAdminRules_init(5 * 60, __owner);
        _grantRole(ADMIN_ROLE, __owner);

        etherFiDataProvider = IEtherFiDataProvider(__etherFiDataProvider);
    }
}
