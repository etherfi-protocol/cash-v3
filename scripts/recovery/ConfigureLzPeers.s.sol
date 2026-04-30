// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * @notice Prints the 10 `setPeer` calldatas that the operating safe will 3CP-sign
 *         after the AssetRecoveryModule + 5 AssetRecoveryDispatchers are deployed.
 *
 *         - On OP `AssetRecoveryModule.setPeer(destEid, dispatcher)` × 5
 *         - On each dest `AssetRecoveryDispatcher.setPeer(30111, moduleOnOp)` × 5
 *
 * Fill in all six addresses below post-deployment, then run:
 *   forge script scripts/recovery/ConfigureLzPeers.s.sol -vvv
 */
contract ConfigureLzPeers is Script {
    // ── Fill in after deployment ─────────────────────────────────────────────
    address constant RECOVERY_MODULE_OP   = address(0);
    address constant DISPATCHER_ETH       = address(0);
    address constant DISPATCHER_ARB       = address(0);
    address constant DISPATCHER_BASE      = address(0);
    address constant DISPATCHER_BNB       = address(0);
    address constant DISPATCHER_HYPEREVM  = address(0);
    // ─────────────────────────────────────────────────────────────────────────

    uint32 constant OP_EID       = 30_111;
    uint32 constant ETH_EID      = 30_101;
    uint32 constant ARB_EID      = 30_110;
    uint32 constant BASE_EID     = 30_184;
    uint32 constant BNB_EID      = 30_102;
    uint32 constant HYPEREVM_EID = 30_367;

    function run() external pure {
        require(RECOVERY_MODULE_OP  != address(0), "fill RECOVERY_MODULE_OP");
        require(DISPATCHER_ETH      != address(0), "fill DISPATCHER_ETH");
        require(DISPATCHER_ARB      != address(0), "fill DISPATCHER_ARB");
        require(DISPATCHER_BASE     != address(0), "fill DISPATCHER_BASE");
        require(DISPATCHER_BNB      != address(0), "fill DISPATCHER_BNB");
        require(DISPATCHER_HYPEREVM != address(0), "fill DISPATCHER_HYPEREVM");

        address[5] memory dispatchers = [
            DISPATCHER_ETH, DISPATCHER_ARB, DISPATCHER_BASE,
            DISPATCHER_BNB, DISPATCHER_HYPEREVM
        ];
        uint32[5] memory eids = [ETH_EID, ARB_EID, BASE_EID, BNB_EID, HYPEREVM_EID];
        string[5] memory names = ["Ethereum", "Arbitrum", "Base", "BNB", "HyperEVM"];

        console.log("=== On Optimism: RecoveryModule.setPeer(destEid, dispatcher) ===");
        console.log("Target: %s (AssetRecoveryModule)", RECOVERY_MODULE_OP);
        for (uint256 i = 0; i < 5; i++) {
            bytes memory cd = abi.encodeWithSignature(
                "setPeer(uint32,bytes32)", eids[i], _toBytes32(dispatchers[i])
            );
            console.log("-- %s (eid=%s) peer=%s", names[i], eids[i], dispatchers[i]);
            console.logBytes(cd);
        }

        console.log("");
        console.log("=== On each dest chain: AssetRecoveryDispatcher.setPeer(30111, AssetRecoveryModule) ===");
        bytes memory opPeerCd = abi.encodeWithSignature(
            "setPeer(uint32,bytes32)", OP_EID, _toBytes32(RECOVERY_MODULE_OP)
        );
        for (uint256 i = 0; i < 5; i++) {
            console.log("-- %s (target=%s)", names[i], dispatchers[i]);
            console.logBytes(opPeerCd);
        }
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
