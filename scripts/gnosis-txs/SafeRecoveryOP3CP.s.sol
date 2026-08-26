// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig } from "../recovery/RecoveryDeployConfig.sol";

/**
 * @notice Generates the OP 3CP JSON to register the SafeAssetRecoveryModule as a DEFAULT module.
 *         Bundle contains a single tx:
 *         EtherFiDataProvider.configureDefaultModules([SafeAssetRecoveryModule], [true]),
 *         signed by the operating safe. configureDefaultModules whitelists AND marks it default in
 *         one call, so the module is enabled on every safe automatically (no per-safe enable) —
 *         matching every other fund-moving module. No role grants (PAUSER/UNPAUSER already held on
 *         OP) and no LayerZero peers — same-chain module.
 *
 * Reads SafeAssetRecoveryModule + EtherFiDataProvider from deployments.json.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/SafeRecoveryOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract SafeRecoveryOP3CP is GnosisHelpers, Utils, Test {
    function run() public {
        require(block.chainid == 10, "must be Optimism");

        string memory deployments = readDeploymentFile();
        address module = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "SafeAssetRecoveryModule"));
        address dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));

        require(module != address(0), "SafeAssetRecoveryModule not found in deployments.json");
        require(dataProvider != address(0), "EtherFiDataProvider not found");

        string memory safe = addressToHex(RecoveryDeployConfig.OPERATING_SAFE);
        string memory txs = _getGnosisHeader("10", safe);

        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(dataProvider),
            iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, flags)),
            "0", true
        )));

        vm.createDir("./output", true);
        string memory path = "./output/SafeRecovery3CP-op-10.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);
        console.log("Simulation passed");
    }
}
