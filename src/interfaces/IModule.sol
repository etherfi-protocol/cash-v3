// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IModule {
    /**
     * @notice Returns the current nonce for a Safe
     * @param safe The Safe address to query
     * @return Current nonce value
     * @dev Nonces are used to prevent signature replay attacks
     */
    function getNonce(address safe) external view returns (uint256);

    /**
     * @notice Sets up a new Safe's Module with initial configuration
     * @dev Override this function to configure a module initially
     * @param data The encoded initialization data
     */
    function setupModule(bytes calldata data) external;
}
