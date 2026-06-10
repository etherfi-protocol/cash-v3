// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IConfigurableOFT
 * @author ether.fi
 * @notice Interface for an OFT bridge that pulls its LayerZero security config
 *         (DVNs / libraries) from a shared {OFTConfigRegistry} and applies it to
 *         itself on the endpoint.
 */
interface IConfigurableOFT {
    /**
     * @notice Pulls the canonical config from the registry and applies it to this
     *         bridge's own endpoint rows for each destination.
     * @param dstEids Destination endpoint IDs to (re)configure
     */
    function syncConfig(uint32[] calldata dstEids) external;

    /// @notice The shared config registry this bridge reads from
    function configRegistry() external view returns (address);
}
