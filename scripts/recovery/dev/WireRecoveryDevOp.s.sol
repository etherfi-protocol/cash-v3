// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { AssetRecoveryModule } from "../../../src/modules/recovery/AssetRecoveryModule.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice DEV-ONLY. Final wiring step: on OP, point the AssetRecoveryModule at the dest
 *         chain's dispatcher proxy. Run AFTER the dest-chain script so the dispatcher exists
 *         and already has its peer set — otherwise an early `recover()` would land on a
 *         dispatcher that doesn't know about the OP peer and revert in `_lzReceive`.
 *
 * Env:
 *   ENV=dev
 *   PRIVATE_KEY   — module owner (deployer EOA from step 1)
 *   MODULE_OP     — AssetRecoveryModule address from DeployRecoveryDevOp
 *   DEST_EID      — destination LZ v2 EID (Base = 30184)
 *   DISPATCHER    — AssetRecoveryDispatcher proxy on dest chain
 */
contract WireRecoveryDevOp is Utils {
    function run() external {
        require(block.chainid == 10, "must be Optimism");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address moduleOp = vm.envAddress("MODULE_OP");
        uint32 destEid = uint32(vm.envUint("DEST_EID"));
        address dispatcher = vm.envAddress("DISPATCHER");

        vm.startBroadcast(deployerPk);
        AssetRecoveryModule(moduleOp).setPeer(destEid, bytes32(uint256(uint160(dispatcher))));
        vm.stopBroadcast();

        console.log("=== Dev OP recovery module peer set ===");
        console.log("Module     : %s", moduleOp);
        console.log("destEid    : %s", destEid);
        console.log("Dispatcher : %s", dispatcher);
    }
}
