// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * @notice Prints the 12 `setPeer` calldatas that the operating safe will 3CP-sign
 *         after the RecoveryModule + 6 TopUpDispatchers are deployed.
 *
 *         - On OP `RecoveryModule.setPeer(destEid, dispatcher)` × 6
 *         - On each dest `TopUpDispatcher.setPeer(30111, moduleOnOp)` × 6
 *
 * Fill in all seven addresses below post-deployment, then run:
 *   forge script scripts/recovery/ConfigureLzPeers.s.sol -vvv
 */
contract ConfigureLzPeers is Script {
    // ── Fill in after deployment ─────────────────────────────────────────────
    address constant RECOVERY_MODULE_OP = address(0);
    address constant DISPATCHER_ETH     = address(0);
    address constant DISPATCHER_ARB     = address(0);
    address constant DISPATCHER_BASE    = address(0);
    address constant DISPATCHER_LINEA   = address(0);
    address constant DISPATCHER_POLYGON = address(0);
    address constant DISPATCHER_AVAX    = address(0);
    // ─────────────────────────────────────────────────────────────────────────

    uint32 constant OP_EID       = 30_111;
    uint32 constant ETH_EID      = 30_101;
    uint32 constant ARB_EID      = 30_110;
    uint32 constant BASE_EID     = 30_184;
    uint32 constant LINEA_EID    = 30_183;
    uint32 constant POLYGON_EID  = 30_109;
    uint32 constant AVAX_EID     = 30_106;

    function run() external pure {
        require(RECOVERY_MODULE_OP != address(0), "fill RECOVERY_MODULE_OP");
        require(DISPATCHER_ETH     != address(0), "fill DISPATCHER_ETH");
        require(DISPATCHER_ARB     != address(0), "fill DISPATCHER_ARB");
        require(DISPATCHER_BASE    != address(0), "fill DISPATCHER_BASE");
        require(DISPATCHER_LINEA   != address(0), "fill DISPATCHER_LINEA");
        require(DISPATCHER_POLYGON != address(0), "fill DISPATCHER_POLYGON");
        require(DISPATCHER_AVAX    != address(0), "fill DISPATCHER_AVAX");

        address[6] memory dispatchers = [
            DISPATCHER_ETH, DISPATCHER_ARB, DISPATCHER_BASE,
            DISPATCHER_LINEA, DISPATCHER_POLYGON, DISPATCHER_AVAX
        ];
        uint32[6] memory eids = [ETH_EID, ARB_EID, BASE_EID, LINEA_EID, POLYGON_EID, AVAX_EID];
        string[6] memory names = ["Ethereum", "Arbitrum", "Base", "Linea", "Polygon", "Avalanche"];

        console.log("=== On Optimism: RecoveryModule.setPeer(destEid, dispatcher) ===");
        console.log("Target: %s (RecoveryModule)", RECOVERY_MODULE_OP);
        for (uint256 i = 0; i < 6; i++) {
            bytes memory cd = abi.encodeWithSignature(
                "setPeer(uint32,bytes32)", eids[i], _toBytes32(dispatchers[i])
            );
            console.log("-- %s (eid=%s) peer=%s", names[i], eids[i], dispatchers[i]);
            console.logBytes(cd);
        }

        console.log("");
        console.log("=== On each dest chain: TopUpDispatcher.setPeer(30111, RecoveryModule) ===");
        bytes memory opPeerCd = abi.encodeWithSignature(
            "setPeer(uint32,bytes32)", OP_EID, _toBytes32(RECOVERY_MODULE_OP)
        );
        for (uint256 i = 0; i < 6; i++) {
            console.log("-- %s (target=%s)", names[i], dispatchers[i]);
            console.logBytes(opPeerCd);
        }
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
