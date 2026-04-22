// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title RoleRegistryMock
 * @notice Minimal stub of `IRoleRegistry` exposing only the `onlyPauser` / `onlyUnpauser`
 *         checks consumed by `TopUpDispatcher` and `RecoveryModule`. Hard-codes a single
 *         authorized pauser and unpauser set at construction.
 */
contract RoleRegistryMock {
    address public pauser;
    address public unpauser;

    error NotPauser();
    error NotUnpauser();

    constructor(address _pauser, address _unpauser) {
        pauser = _pauser;
        unpauser = _unpauser;
    }

    function onlyPauser(address account) external view {
        if (account != pauser) revert NotPauser();
    }

    function onlyUnpauser(address account) external view {
        if (account != unpauser) revert NotUnpauser();
    }
}
