// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AssetRecoveryDispatcher } from "../../src/top-up/AssetRecoveryDispatcher.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @notice Deploys a singleton `AssetRecoveryDispatcher` on one destination chain. Run once
 *         per chain in {Ethereum, Arbitrum, Base, BNB, HyperEVM}.
 *
 *         The UUPS proxy is deployed via CREATE3 so it lands at the same address on every
 *         chain (the proxy address is load-bearing for LZ peer wiring). The impl behind
 *         the proxy is deployed via regular CREATE (its address is ephemeral — upgradeable).
 *
 * Env:
 *   LZ_ENDPOINT    — LayerZero v2 endpoint on the current chain (see lz-config.json)
 *   TOPUP_FACTORY  — local TopUpFactory proxy address (used for lazy TopUp deploy on recovery)
 */
contract DeployAssetRecoveryDispatcher is Utils, RecoveryDeployHelper {
    function run() external {
        require(RecoveryDeployConfig.NICKS_FACTORY.code.length > 0, "Nick's factory not on this chain");

        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address topUpFactory = vm.envAddress("TOPUP_FACTORY");
        require(topUpFactory.code.length > 0, "TOPUP_FACTORY has no code on this chain");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        require(roleRegistry != address(0), "RoleRegistry not found in deployments.json");

        address predictedProxy = _predictImpl(RecoveryDeployConfig.SALT_RECOVERY_DISPATCHER_PROXY);
        console.log("Predicted proxy address: %s", predictedProxy);

        vm.startBroadcast();

        // 1. Deploy impl via regular CREATE (address is ephemeral, upgradeable)
        AssetRecoveryDispatcher impl = new AssetRecoveryDispatcher(lzEndpoint, RecoveryDeployConfig.OP_EID, topUpFactory);

        // 2. Deploy proxy via CREATE3 (same address on all dest chains)
        bytes memory proxyCreationCode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(address(impl), abi.encodeWithSelector(AssetRecoveryDispatcher.initialize.selector, RecoveryDeployConfig.OPERATING_SAFE, roleRegistry)));
        address proxyAddr = _deployCreate3(proxyCreationCode, RecoveryDeployConfig.SALT_RECOVERY_DISPATCHER_PROXY);
        require(proxyAddr == predictedProxy, "proxy address mismatch");

        AssetRecoveryDispatcher dispatcher = AssetRecoveryDispatcher(proxyAddr);

        vm.stopBroadcast();

        // --- Post-deploy verification: read back immutables + proxy state ---
        require(dispatcher.owner() == RecoveryDeployConfig.OPERATING_SAFE, "VERIFY FAILED: proxy owner != OPERATING_SAFE");
        require(address(dispatcher.endpoint()) == lzEndpoint, "VERIFY FAILED: endpoint mismatch");
        require(uint256(dispatcher.SOURCE_EID()) == uint256(RecoveryDeployConfig.OP_EID), "VERIFY FAILED: SOURCE_EID != 30111");
        require(address(dispatcher.TOPUP_FACTORY()) == topUpFactory, "VERIFY FAILED: TOPUP_FACTORY mismatch");
        require(address(dispatcher.roleRegistry()) == roleRegistry, "VERIFY FAILED: roleRegistry mismatch");

        // Verify EIP-1967 impl slot points at our deployed impl
        address storedImpl = address(uint160(uint256(vm.load(proxyAddr, RecoveryDeployConfig.EIP1967_IMPL_SLOT))));
        require(storedImpl == address(impl), "VERIFY FAILED: EIP-1967 impl slot != deployed impl");

        bytes32 implCodeHash = keccak256(address(impl).code);
        bytes32 proxyCodeHash = keccak256(proxyAddr.code);

        console.log("chainId                       : %s", block.chainid);
        console.log("AssetRecoveryDispatcher impl  : %s", address(impl));
        console.log("AssetRecoveryDispatcher proxy : %s", proxyAddr);
        console.log("LZ endpoint                   : %s", lzEndpoint);
        console.log("TopUpFactory                  : %s", topUpFactory);
        console.log("RoleRegistry                  : %s", roleRegistry);
        console.log("Source EID                    : %s (Optimism)", RecoveryDeployConfig.OP_EID);
        console.log("Delegate / owner              : %s", RecoveryDeployConfig.OPERATING_SAFE);
        console.log("Impl runtime bytecode hash:");
        console.logBytes32(implCodeHash);
        console.log("Proxy runtime bytecode hash:");
        console.logBytes32(proxyCodeHash);
    }
}
