// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableProxy } from "./UpgradeableProxy.sol";

/// @title EtherFiPlaceholder
/// @notice Minimal upgradeable contract used to reserve deterministic CREATE3 proxy addresses.
///         Can be upgraded to the real implementation later by the RoleRegistry owner.
contract EtherFiPlaceholder is UpgradeableProxy {
    constructor() {
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }
}
