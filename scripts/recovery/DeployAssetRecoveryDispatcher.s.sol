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
 *         per chain in {Ethereum, Arbitrum, Base, BNB, HyperEVM}. Impl is deployed via
 *         Nick's CREATE3 factory with `SALT_RECOVERY_DISPATCHER_IMPL` so it lands at the
 *         same address on every chain.
 *
 * Env:
 *   PRIVATE_KEY    — deployer key
 *   LZ_ENDPOINT    — LayerZero v2 endpoint on the current chain (see lz-config.json)
 *   TOPUP_FACTORY  — local TopUpFactory proxy address (used for lazy TopUp deploy on recovery)
 */
contract DeployAssetRecoveryDispatcher is Utils, RecoveryDeployHelper {
    function run() external {
        require(RecoveryDeployConfig.NICKS_FACTORY.code.length > 0, "Nick's factory not on this chain");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address topUpFactory = vm.envAddress("TOPUP_FACTORY");
        require(topUpFactory.code.length > 0, "TOPUP_FACTORY has no code on this chain");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        require(roleRegistry != address(0), "RoleRegistry not found in deployments.json");

        address predictedImpl = _predictImpl(RecoveryDeployConfig.SALT_RECOVERY_DISPATCHER_IMPL);
        console.log("Predicted impl address: %s", predictedImpl);

        vm.startBroadcast(deployerPk);

        address impl = _deployCreate3(abi.encodePacked(type(AssetRecoveryDispatcher).creationCode, abi.encode(lzEndpoint, RecoveryDeployConfig.OP_EID, topUpFactory)), RecoveryDeployConfig.SALT_RECOVERY_DISPATCHER_IMPL);
        require(impl == predictedImpl, "impl address mismatch");

        AssetRecoveryDispatcher dispatcher = AssetRecoveryDispatcher(address(new UUPSProxy(impl, abi.encodeWithSelector(AssetRecoveryDispatcher.initialize.selector, RecoveryDeployConfig.OPERATING_SAFE, roleRegistry))));

        vm.stopBroadcast();

        console.log("chainId                       : %s", block.chainid);
        console.log("AssetRecoveryDispatcher impl  : %s", impl);
        console.log("AssetRecoveryDispatcher proxy : %s", address(dispatcher));
        console.log("LZ endpoint                   : %s", lzEndpoint);
        console.log("TopUpFactory                  : %s", topUpFactory);
        console.log("RoleRegistry                  : %s", roleRegistry);
        console.log("Source EID                    : %s (Optimism)", RecoveryDeployConfig.OP_EID);
        console.log("Delegate / owner              : %s", RecoveryDeployConfig.OPERATING_SAFE);
    }
}
