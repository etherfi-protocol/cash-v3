// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { ILayerZeroEndpointV2, MessagingParams, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { Utils } from "../../utils/Utils.sol";
import { RecoverySetConfigLib } from "../RecoverySetConfigLib.sol";
import { RecoveryMessageLib } from "../../../src/libraries/RecoveryMessageLib.sol";

/**
 * @notice DEV-ONLY. Applies the recovery ULN setConfig on the **dev** contracts using the deployer
 *         EOA — which is the OApp delegate on dev, so no 3CP. It calls the exact same
 *         `RecoverySetConfigLib` calldata the prod 3CPs use, so a green run here validates that
 *         calldata against live state before any prod signing.
 *
 *         - On Optimism (10): configures the dev module's SEND ULN toward `DEST_EID`, then asserts
 *           the route quotes (non-zero native fee) — this proves the send path end-to-end on dev.
 *         - On a dest chain (e.g. opBNB 204): configures the dev dispatcher's RECEIVE ULN from OP.
 *           Requires the dev dispatcher to already exist in deployments/dev/<id> (DeployRecoveryDevDest).
 *
 * Env:
 *   ENV=dev
 *   PRIVATE_KEY  — dev deployer EOA (the OApp delegate on dev)
 *   DEST_EID     — required on OP only (e.g. 30202 for opBNB)
 *
 * Send (OP):     ENV=dev DEST_EID=30202 forge script scripts/recovery/dev/DevRecoverySetConfig.s.sol \
 *                  --rpc-url $OPTIMISM_RPC --broadcast
 * Receive (opBNB): ENV=dev forge script scripts/recovery/dev/DevRecoverySetConfig.s.sol \
 *                  --rpc-url $OPBNB_RPC --broadcast
 */
contract DevRecoverySetConfig is Utils {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory deployments = readDeploymentFile();

        if (block.chainid == 10) {
            uint32 destEid = uint32(vm.envUint("DEST_EID"));
            address module = stdJson.readAddress(deployments, ".addresses.AssetRecoveryModule");
            require(module != address(0), "dev AssetRecoveryModule not found");

            (address target, bytes memory data) = RecoverySetConfigLib.opSendConfig(module, destEid);
            vm.startBroadcast(pk);
            (bool ok, ) = target.call(data);
            require(ok, "SEND setConfig reverted (is the EOA the module delegate?)");
            vm.stopBroadcast();

            console.log("Applied SEND setConfig on dev module %s for dstEid %s", module, destEid);
            _assertQuotable(module, destEid);
        } else {
            address dispatcher = stdJson.readAddress(deployments, ".addresses.AssetRecoveryDispatcher");
            require(dispatcher != address(0), "dev AssetRecoveryDispatcher not found (deploy DeployRecoveryDevDest first)");

            (address target, bytes memory data) = RecoverySetConfigLib.destReceiveConfig(dispatcher, block.chainid);
            vm.startBroadcast(pk);
            (bool ok, ) = target.call(data);
            require(ok, "RECEIVE setConfig reverted (is the EOA the dispatcher delegate?)");
            vm.stopBroadcast();

            console.log("Applied RECEIVE setConfig on dev dispatcher %s (srcEid %s)", dispatcher, RecoverySetConfigLib.OP_EID);
        }
    }

    /// Post-apply proof the send config makes the route dispatchable (quote must not revert / be zero).
    function _assertQuotable(address module, uint32 destEid) internal view {
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: address(0xdEaD), token: address(0xbEEF), recipient: address(0xCAFE), salt: bytes32(uint256(1))
        }));
        // LZ v2 type-3 options: one executor lzReceive option, 500k dest gas.
        bytes memory options = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(500_000));
        MessagingParams memory p = MessagingParams({
            dstEid: destEid,
            receiver: bytes32(uint256(uint160(0x418e0af7c750Ba5cbffC5C2a8398591755926A29))), // dispatcher (receiver is not priced)
            message: message,
            options: options,
            payInLzToken: false
        });
        MessagingFee memory fee = ILayerZeroEndpointV2(RecoverySetConfigLib.ENDPOINT).quote(p, module);
        require(fee.nativeFee > 0, "quote returned zero native fee");
        console.log("Route quotable after setConfig - nativeFee:", fee.nativeFee);
    }
}
