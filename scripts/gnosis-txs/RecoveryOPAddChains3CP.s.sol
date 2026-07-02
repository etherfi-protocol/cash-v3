// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig } from "../recovery/RecoveryDeployConfig.sol";
import { RecoverySetConfigLib } from "../recovery/RecoverySetConfigLib.sol";

/**
 * @notice The single Optimism-side 3CP that adds every new destination chain as a LZ peer on the
 *         singleton cross-chain AssetRecoveryModule. One bundle, signed by the operating safe (the
 *         module's OApp owner/delegate), with one setPeer call per chain:
 *           - setPeer(30109, dispatcher)   // Polygon
 *           - setPeer(30145, dispatcher)   // Gnosis
 *           - setPeer(30202, dispatcher)   // opBNB
 *
 *         The dispatcher is the canonical CREATE3 singleton (same address on every dest chain), so
 *         the peer value is identical for all. Peers must be set on BOTH sides (this + each dest
 *         3CP's dispatcher.setPeer(30111, module)) before recovery to a chain works.
 *
 *         opBNB additionally gets a send-ULN endpoint.setConfig() (no default DVN pathway
 *         OP->opBNB) pinning the LZ Labs DVN — see RecoverySetConfigLib.
 *
 * ponytail TODO (ALL_CHAINS_LAUNCH.md), before go-live:
 *   - Avalanche: add setPeer(30106, dispatcher).
 *
 * Run on Optimism:
 *   source .env && forge script scripts/gnosis-txs/RecoveryOPAddChains3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract RecoveryOPAddChains3CP is GnosisHelpers, Utils, Test {
    // Singleton dispatcher — same CREATE3 address on every destination chain.
    address constant DISPATCHER = 0x418e0af7c750Ba5cbffC5C2a8398591755926A29;

    uint32 constant POLYGON_EID = 30109;
    uint32 constant GNOSIS_EID  = 30145;
    uint32 constant OPBNB_EID   = 30202;

    function run() public {
        require(block.chainid == 10, "must run on Optimism (source)");

        string memory deployments = readDeploymentFile();
        address module = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "AssetRecoveryModule"));
        require(module != address(0), "AssetRecoveryModule not found");

        bytes32 peer = bytes32(uint256(uint160(DISPATCHER)));
        string memory safe = addressToHex(RecoveryDeployConfig.OPERATING_SAFE);
        string memory txs = _getGnosisHeader("10", safe);

        txs = _appendSetPeer(txs, module, POLYGON_EID, peer, false);
        txs = _appendSetPeer(txs, module, GNOSIS_EID,  peer, false);
        txs = _appendSetPeer(txs, module, OPBNB_EID,   peer, false);

        // opBNB: pin the LZ Labs DVN on the module's SEND config (no default DVN pathway).
        (address t1, bytes memory d1) = RecoverySetConfigLib.opSendConfig(module, OPBNB_EID);
        txs = _appendCall(txs, t1, d1, true); // last call in the bundle

        vm.createDir("./output", true);
        string memory path = "./output/Recovery3CP-op-add-chains.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);
        console.log("Simulation passed");
    }

    function _appendSetPeer(string memory txs, address module, uint32 eid, bytes32 peer, bool last)
        internal
        view
        returns (string memory)
    {
        return string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(module),
            iToHex(abi.encodeWithSelector(IOAppCore.setPeer.selector, eid, peer)),
            "0", last
        )));
    }

    function _appendCall(string memory txs, address target, bytes memory data, bool last)
        internal
        view
        returns (string memory)
    {
        return string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(target), iToHex(data), "0", last)));
    }
}
