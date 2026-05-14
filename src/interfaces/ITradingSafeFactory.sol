// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ITradingSafeFactory
 * @author ether.fi
 * @notice Destination-chain TradingSafe factory surface consumed by the cross-chain
 *         ownership bridge.
 * @dev Implementation lives in the TradingSafe project (COR-728). Defined here so that
 *      bridge contracts can resolve `sourceSafe → tradingSafe` without taking a hard
 *      dependency on the full factory interface.
 */
interface ITradingSafeFactory {
    /**
     * @notice Returns the deterministic TradingSafe address for a given source-chain safe.
     * @param sourceSafe Source-chain safe address.
     * @return The pre-computed destination TradingSafe address (may not yet have code).
     */
    function getDeterministicAddress(address sourceSafe) external view returns (address);
}
