// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

/**
 * @title RecoveryDeployConfig
 * @notice Constants shared across Fund Recovery deploy + verify scripts.
 *         Impl salts are keccak256 of `"Recovery.<ContractName>Impl.v1"` so the produced
 *         addresses are identical on every chain (via Nick's CREATE3 factory) and can be
 *         independently recomputed by the 3CP reviewer.
 */
library RecoveryDeployConfig {
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant NICKS_FACTORY  = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 internal constant EIP1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant OZ_INIT_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Impl salts — do not change after first deploy (addresses are load-bearing for verification).
    bytes32 internal constant SALT_RECOVERY_MODULE_IMPL  = keccak256("Recovery.RecoveryModuleImpl.v1");
    bytes32 internal constant SALT_TOPUP_DISPATCHER_IMPL = keccak256("Recovery.TopUpDispatcherImpl.v1");
    bytes32 internal constant SALT_TOPUP_V2_IMPL         = keccak256("Recovery.TopUpV2Impl.v1");

    uint32 internal constant OP_EID = 30_111;
}

/**
 * @title RecoveryDeployHelper
 * @notice Nick's-factory-based CREATE3 deployment + prediction helpers. Mirrors the pattern
 *         established by `scripts/ReserveAddresses.s.sol` so verifier scripts can recompute
 *         impl addresses without referring to a specific deployer EOA.
 */
abstract contract RecoveryDeployHelper {
    function _predictImpl(bytes32 salt) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(salt, RecoveryDeployConfig.NICKS_FACTORY);
    }

    function _deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = _predictImpl(salt);
        if (deployed.code.length > 0) return deployed; // idempotent

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff",
            RecoveryDeployConfig.NICKS_FACTORY,
            salt,
            CREATE3.PROXY_INITCODE_HASH
        )))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = RecoveryDeployConfig.NICKS_FACTORY.call(
                abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3")
            );
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");
        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }
}
