// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IEtherFiHook
 * @author ether.fi
 * @notice Interface for the EtherFiHook contract that implements operation hooks
 */
interface IEtherFiHook {
    /**
     * @notice Updates the cash module address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param cashModule New cash module address to set
     */
    function setCashModule(address cashModule) external;

    /**
     * @notice Hook called before module operations
     * @dev Currently implemented as a view function with no effects
     * @param module Address of the module being operated on
     */
    function preOpHook(address module) external view;

    /**
     * @notice Hook called after module operations
     * @dev Currently implemented as a view function with no effects
     * @param module Address of the module being operated on
     */
    function postOpHook(address module) external view;

    /**
     * @notice Role identifier for administrative privileges
     * @return bytes32 The keccak256 hash of "ADMIN_ROLE"
     */
    function ADMIN_ROLE() external view returns (bytes32);
}
