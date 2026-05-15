// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig } from "../recovery/RecoveryDeployConfig.sol";

/**
 * @notice Generates the OP 3CP JSON. Bundle contains:
 *         1. configureModules([AssetRecoveryModule], [true])
 *         2-6. module.setPeer(destEid, dispatcher) x 5
 *
 * Reads AssetRecoveryModule + EtherFiDataProvider from deployments.json.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/RecoveryOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract RecoveryOP3CP is GnosisHelpers, Utils, Test {
    address constant DISPATCHER = 0x418e0af7c750Ba5cbffC5C2a8398591755926A29;

    uint32 constant ETH_EID = 30101;
    uint32 constant ARB_EID = 30110;
    uint32 constant BASE_EID = 30184;
    uint32 constant BNB_EID = 30102;
    uint32 constant HYPEREVM_EID = 30367;

    function run() public {
        require(block.chainid == 10, "must be Optimism");

        string memory deployments = readDeploymentFile();
        address module = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "AssetRecoveryModule"));
        address dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));

        require(module != address(0), "AssetRecoveryModule not found");
        require(dataProvider != address(0), "EtherFiDataProvider not found");

        string memory safe = addressToHex(RecoveryDeployConfig.OPERATING_SAFE);
        string memory txs = _getGnosisHeader("10", safe);

        // 1. configureModules([module], [true])
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(dataProvider),
            iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, modules, flags)),
            "0", false
        )));

        // 2-6. module.setPeer(destEid, dispatcher) x 5
        bytes32 peerBytes = bytes32(uint256(uint160(DISPATCHER)));
        uint32[5] memory eids = [ETH_EID, ARB_EID, BASE_EID, BNB_EID, HYPEREVM_EID];

        for (uint256 i = 0; i < 5; i++) {
            bool isLast = (i == 4);
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(module),
                iToHex(abi.encodeWithSelector(IOAppCore.setPeer.selector, eids[i], peerBytes)),
                "0", isLast
            )));
        }

        vm.createDir("./output", true);
        string memory path = "./output/Recovery3CP-op-10.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);
        console.log("Simulation passed");
    }
}
