// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Utils } from "./utils/Utils.sol";

/// @dev Minimal view of the LayerZero OApp peer interface (OAppCore).
interface ILayerZeroPeer {
    function setPeer(uint32 eid, bytes32 peer) external;
    function peers(uint32 eid) external view returns (bytes32);
    function owner() external view returns (address);
}

/**
 * @title WireOFTPeers
 * @author ether.fi
 * @notice EOA-driven peer wiring for the PEPE pathway: points each chain's bridge at its
 *         counterpart so messages route end-to-end. Run once per chain (branches on chainId):
 *         on mainnet it sets the adapter's OP peer; on Optimism it sets the iTOKEN's ETH peer.
 * @dev The caller must be the OApp delegate/owner of the local bridge (the delegate set at
 *      listing time; the deployer EOA in the EOA flow). Reads the local bridge from this chain's
 *      deployments.json and the remote bridge from the other chain's deployments.json, so list
 *      the asset on BOTH chains first. Idempotent: skips if the peer is already set. Run:
 *
 *        PRIVATE_KEY=<delegate> forge script scripts/WireOFTPeers.s.sol --rpc-url mainnet  --broadcast
 *        PRIVATE_KEY=<delegate> forge script scripts/WireOFTPeers.s.sol --rpc-url optimism --broadcast
 */
contract WireOFTPeers is Utils {
    uint32 constant ETH_EID = 30101;
    uint32 constant OP_EID = 30111;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Resolve local/remote bridges and the remote EID from the chain we're running on.
        string memory localKey;
        string memory remoteKey;
        uint256 remoteChainId;
        uint32 remoteEid;
        if (block.chainid == 1) {
            (localKey, remoteKey, remoteChainId, remoteEid) = ("OFTAdapter_PEPE", "ShadowOFT_iPEPE", 10, OP_EID);
        } else if (block.chainid == 10) {
            (localKey, remoteKey, remoteChainId, remoteEid) = ("ShadowOFT_iPEPE", "OFTAdapter_PEPE", 1, ETH_EID);
        } else {
            revert("run on Ethereum mainnet (1) or Optimism (10)");
        }

        address localBridge = stdJson.readAddress(readDeploymentFile(), string.concat(".addresses.", localKey));
        address remoteBridge = stdJson.readAddress(_readRemoteDeployments(remoteChainId), string.concat(".addresses.", remoteKey));

        require(
            ILayerZeroPeer(localBridge).owner() == deployer,
            "deployer must be the OApp delegate/owner of the local bridge"
        );

        bytes32 peer = bytes32(uint256(uint160(remoteBridge)));
        bool alreadySet = ILayerZeroPeer(localBridge).peers(remoteEid) == peer;

        if (!alreadySet) {
            vm.startBroadcast(pk);
            ILayerZeroPeer(localBridge).setPeer(remoteEid, peer);
            vm.stopBroadcast();
        }

        if (alreadySet) console.log("Peer already set; nothing to do");
        console.log("Wired peer on chainId", block.chainid);
        console.log("  local bridge: ", localBridge);
        console.log("  remote eid:   ", remoteEid);
        console.log("  remote bridge:", remoteBridge);
    }

    /// @dev Reads the deployments.json of another chain (different chainId directory, same ENV).
    function _readRemoteDeployments(uint256 remoteChainId) internal view returns (string memory) {
        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(remoteChainId), "/deployments.json");
        return vm.readFile(path);
    }
}
