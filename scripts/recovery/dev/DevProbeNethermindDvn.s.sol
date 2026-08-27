// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

import { Utils } from "../../utils/Utils.sol";

/**
 * @notice DEV-ONLY EXPERIMENT (not for prod). Re-points the recovery OApps' ULN config at the
 *         **Nethermind** DVN only (instead of LZ Labs), to test whether Nethermind operationally
 *         verifies OP<->opBNB where the LZ Labs DVN priced-but-never-attested. Run by the dev
 *         delegate EOA on each chain:
 *           - OP (10):    send ULN on the dev AssetRecoveryModule toward dstEid 30202
 *           - opBNB (204): receive ULN on the dev AssetRecoveryDispatcher from srcEid 30111
 *         After running BOTH, re-trigger a recovery through the dev app and watch LZ Scan.
 *
 *         Nethermind-only (single required DVN) on purpose: pairing it with LZ Labs would still
 *         stall on LZ Labs. Addresses: OP Nethermind = weETH-verified; opBNB Nethermind = LZ metadata
 *         (both confirmed live contracts).
 *
 * Env: ENV=dev, PRIVATE_KEY (dev delegate)
 * Run: ENV=dev forge script scripts/recovery/dev/DevProbeNethermindDvn.s.sol --rpc-url $OPTIMISM_RPC --broadcast
 *      ENV=dev forge script scripts/recovery/dev/DevProbeNethermindDvn.s.sol --rpc-url $OPBNB_RPC   --broadcast
 */
contract DevProbeNethermindDvn is Utils {
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32  constant CONFIG_TYPE_ULN = 2;
    uint64  constant CONFIRMATIONS = 15;

    uint32  constant OP_EID    = 30111;
    uint32  constant OPBNB_EID = 30202;

    // OP send side
    address constant OP_SEND_ULN       = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95;
    address constant OP_NETHERMIND_DVN = 0xa7b5189bcA84Cd304D8553977c7C614329750d99; // weETH-verified

    // opBNB receive side
    address constant OPBNB_RECEIVE_ULN     = 0x9c9e25F9fC4e8134313C2a9f5c719f5c9F4fbD95;
    address constant OPBNB_NETHERMIND_DVN  = 0x6a4C9096F162f0ab3C0517B0a40dc1CE44785e16; // LZ metadata

    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory deployments = readDeploymentFile();

        if (block.chainid == 10) {
            address module = stdJson.readAddress(deployments, ".addresses.AssetRecoveryModule");
            require(module != address(0), "dev AssetRecoveryModule missing");
            _setConfig(pk, module, OP_SEND_ULN, OPBNB_EID, OP_NETHERMIND_DVN);
            console.log("OP SEND ULN -> Nethermind for dstEid 30202 on module %s", module);
        } else if (block.chainid == 204) {
            address dispatcher = stdJson.readAddress(deployments, ".addresses.AssetRecoveryDispatcher");
            require(dispatcher != address(0), "dev AssetRecoveryDispatcher missing");
            _setConfig(pk, dispatcher, OPBNB_RECEIVE_ULN, OP_EID, OPBNB_NETHERMIND_DVN);
            console.log("opBNB RECEIVE ULN -> Nethermind for srcEid 30111 on dispatcher %s", dispatcher);
        } else {
            revert("run on OP (10) or opBNB (204)");
        }
    }

    function _setConfig(uint256 pk, address oapp, address lib, uint32 eid, address dvn) internal {
        address[] memory req = new address[](1);
        req[0] = dvn;
        UlnConfig memory uln = UlnConfig(CONFIRMATIONS, 1, 0, 0, req, new address[](0));
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({ eid: eid, configType: CONFIG_TYPE_ULN, config: abi.encode(uln) });

        vm.startBroadcast(pk);
        (bool ok, ) = ENDPOINT.call(abi.encodeCall(IMessageLibManager.setConfig, (oapp, lib, params)));
        require(ok, "setConfig reverted (is the EOA the OApp delegate?)");
        vm.stopBroadcast();
    }
}
