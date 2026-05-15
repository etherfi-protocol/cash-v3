// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../../src/UUPSProxy.sol";
import { BeaconFactory } from "../../../src/top-up/TopUpFactory.sol";
import { AssetRecoveryDispatcher } from "../../../src/top-up/AssetRecoveryDispatcher.sol";
import { TopUpV2 } from "../../../src/top-up/TopUpV2.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice DEV-ONLY. Deploys the dest-chain half of the recovery flow (dispatcher impl +
 *         proxy + TopUpV2 impl) on a single dest chain (Base in our test) and wires the
 *         dest-side state: dispatcher.setPeer(OP) + BeaconFactory.upgradeBeaconImplementation.
 *         Deployer EOA is used as delegate/owner everywhere.
 *
 * Env:
 *   ENV=dev       — required so Utils reads from deployments/dev/<chainId>/
 *   PRIVATE_KEY   — deployer (must be RoleRegistry owner on this dest chain)
 *   LZ_ENDPOINT   — LayerZero v2 endpoint on this chain
 *   MODULE_OP     — AssetRecoveryModule address from DeployRecoveryDevOp
 *   WETH          — WETH address on this chain (Base superchain WETH = 0x4200...0006)
 */
contract DeployRecoveryDevDest is Utils {
    uint32 internal constant OP_EID = 30_111;

    function run() external {
        require(block.chainid != 10, "must NOT be Optimism");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address moduleOp = vm.envAddress("MODULE_OP");
        address weth = vm.envAddress("WETH");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        address topUpFactory = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        require(roleRegistry != address(0), "RoleRegistry missing");
        require(topUpFactory != address(0), "TopUpSourceFactory missing");
        require(topUpFactory.code.length > 0, "TopUpSourceFactory has no code");

        vm.startBroadcast(deployerPk);

        AssetRecoveryDispatcher dispatcherImpl = new AssetRecoveryDispatcher(lzEndpoint, OP_EID, topUpFactory);
        AssetRecoveryDispatcher dispatcher = AssetRecoveryDispatcher(address(
            new UUPSProxy(
                address(dispatcherImpl),
                abi.encodeCall(AssetRecoveryDispatcher.initialize, (deployer, roleRegistry))
            )
        ));

        TopUpV2 topUpV2Impl = new TopUpV2(weth, address(dispatcher));

        dispatcher.setPeer(OP_EID, bytes32(uint256(uint160(moduleOp))));
        BeaconFactory(topUpFactory).upgradeBeaconImplementation(address(topUpV2Impl));

        vm.stopBroadcast();

        console.log("=== Dev dest-chain recovery deployed ===");
        console.log("chainId             : %s", block.chainid);
        console.log("Dispatcher impl     : %s", address(dispatcherImpl));
        console.log("Dispatcher proxy    : %s", address(dispatcher));
        console.log("TopUpV2 impl        : %s", address(topUpV2Impl));
        console.log("TopUpFactory beacon : %s (upgraded to TopUpV2)", topUpFactory);
        console.log("RoleRegistry        : %s", roleRegistry);
        console.log("LZ endpoint         : %s", lzEndpoint);
        console.log("Module on OP (peer) : %s", moduleOp);
        console.log("Owner / delegate    : %s (deployer EOA)", deployer);
        console.log("");
        console.log("Pass DISPATCHER=%s into WireRecoveryDevOp", address(dispatcher));
    }
}
