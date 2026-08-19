// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Utils } from "./Utils.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";

/**
 * @title EtherFiDeployerHelper
 * @author ether.fi
 * @notice Shared script base for deterministic deploys through the on-chain
 *         `EtherFiDeployer` (permissioned CREATE3 factory, same address on every chain).
 *         Deploy scripts inherit this and call `_create3` with a human-readable salt name;
 *         verification scripts use `_predictAddress` with the same name to assert the
 *         deployed address.
 */
abstract contract EtherFiDeployerHelper is Utils {
    /// @notice The on-chain EtherFiDeployer (CreateX-deployed, chain-agnostic address).
    EtherFiDeployer internal constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    /**
     * @dev CREATE3-deploys `creationCode ++ constructorArgs` under `saltName` via the shared
     *      EtherFiDeployer, or returns the existing deterministic address when it already
     *      holds code — making scripts safe to re-run (idempotent).
     * @param saltName Human-readable salt; hashed via `Utils.getSalt`.
     * @param creationCode The contract creation code (`type(C).creationCode`).
     * @param constructorArgs ABI-encoded constructor args (empty bytes if none).
     * @return The deterministic deployment address.
     */
    function _create3(string memory saltName, bytes memory creationCode, bytes memory constructorArgs) internal returns (address) {
        address predicted = _predictAddress(saltName);
        if (predicted.code.length > 0) {
            return predicted;
        }
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }

    /**
     * @dev Returns the deterministic address `_create3(saltName, ...)` deploys to.
     * @param saltName Human-readable salt; hashed via `Utils.getSalt`.
     * @return The predicted address (may not yet have code).
     */
    function _predictAddress(string memory saltName) internal view returns (address) {
        return DEPLOYER.getDeterministicAddress(getSalt(saltName));
    }
}
