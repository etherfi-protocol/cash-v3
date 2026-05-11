// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { AssetRecoveryModule } from "../../src/modules/recovery/AssetRecoveryModule.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @notice Deploys the `AssetRecoveryModule` on Optimism as a plain non-upgradable contract
 *         via Nick's CREATE3 factory with `SALT_RECOVERY_MODULE` so the verifier script can
 *         independently recompute the address. The module is replaced (not upgraded) via
 *         `EtherFiDataProvider.configureModules`, matching the repo precedent for Safe modules.
 *
 * Env:
 *   PRIVATE_KEY    — deployer key
 *   LZ_ENDPOINT    — LayerZero v2 endpoint on OP (see scripts/recovery/lz-config.json)
 *
 * Prints the `EtherFiDataProvider.configureModules([module], [true])` calldata
 * that the operating safe will 3CP-sign to whitelist the module.
 */
contract DeployAssetRecoveryModule is Utils, RecoveryDeployHelper {
    function run() external {
        require(block.chainid == 10, "must be Optimism");
        require(RecoveryDeployConfig.NICKS_FACTORY.code.length > 0, "Nick's factory not on this chain");

        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        require(dataProvider != address(0), "dataProvider not found in deployments.json");

        address predicted = _predictImpl(RecoveryDeployConfig.SALT_RECOVERY_MODULE);
        console.log("Predicted module address: %s", predicted);

        vm.startBroadcast();

        address module = _deployCreate3(
            abi.encodePacked(
                type(AssetRecoveryModule).creationCode,
                abi.encode(dataProvider, lzEndpoint, RecoveryDeployConfig.OPERATING_SAFE)
            ),
            RecoveryDeployConfig.SALT_RECOVERY_MODULE
        );
        require(module == predicted, "module address mismatch");

        vm.stopBroadcast();

        // --- Post-deploy verification: read back immutables to confirm we deployed OUR code ---
        AssetRecoveryModule deployed = AssetRecoveryModule(module);
        require(deployed.owner() == RecoveryDeployConfig.OPERATING_SAFE, "VERIFY FAILED: owner != OPERATING_SAFE");
        require(address(deployed.endpoint()) == lzEndpoint, "VERIFY FAILED: endpoint mismatch");
        require(address(deployed.etherFiDataProvider()) == dataProvider, "VERIFY FAILED: dataProvider mismatch");

        bytes32 codeHash = keccak256(module.code);
        console.log("AssetRecoveryModule : %s", module);
        console.log("DataProvider        : %s", dataProvider);
        console.log("LZ endpoint         : %s", lzEndpoint);
        console.log("Delegate / owner    : %s", RecoveryDeployConfig.OPERATING_SAFE);
        console.log("Runtime bytecode hash (for independent verification):");
        console.logBytes32(codeHash);

        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes memory whitelistCalldata = abi.encodeCall(
            EtherFiDataProvider.configureModules,
            (modules, shouldWhitelist)
        );
        console.log("");
        console.log("3CP calldata - operating safe signs on OP:");
        console.log("  target  : %s (EtherFiDataProvider)", dataProvider);
        console.log("  method  : configureModules([%s], [true])", module);
        console.log("  calldata:");
        console.logBytes(whitelistCalldata);
    }
}
