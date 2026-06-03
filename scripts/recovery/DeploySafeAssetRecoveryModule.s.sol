// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { SafeAssetRecoveryModule } from "../../src/modules/recovery/SafeAssetRecoveryModule.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @notice Deploys the `SafeAssetRecoveryModule` on Optimism as a plain non-upgradable contract via
 *         Nick's CREATE3 factory with `SALT_SAFE_RECOVERY_MODULE`, so the verifier can independently
 *         recompute the address. The module is registered as a DEFAULT module via
 *         `EtherFiDataProvider.configureDefaultModules`, matching the repo precedent for fund-moving
 *         Safe modules (CashModule, swap, liquid) — so it is enabled on every safe automatically.
 *
 * Env:
 *   PRIVATE_KEY — deployer key
 *
 * Prints the `EtherFiDataProvider.configureDefaultModules([module], [true])` calldata the operating
 * safe will 3CP-sign (see SafeRecoveryOP3CP.s.sol).
 */
contract DeploySafeAssetRecoveryModule is Utils, RecoveryDeployHelper {
    function run() external {
        require(block.chainid == 10, "must be Optimism");
        require(RecoveryDeployConfig.NICKS_FACTORY.code.length > 0, "Nick's factory not on this chain");

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        require(dataProvider != address(0), "dataProvider not found in deployments.json");

        address predicted = _predictImpl(RecoveryDeployConfig.SALT_SAFE_RECOVERY_MODULE);
        console.log("Predicted module address: %s", predicted);

        vm.startBroadcast();

        address module = _deployCreate3(
            abi.encodePacked(
                type(SafeAssetRecoveryModule).creationCode,
                abi.encode(dataProvider)
            ),
            RecoveryDeployConfig.SALT_SAFE_RECOVERY_MODULE
        );
        require(module == predicted, "module address mismatch");

        vm.stopBroadcast();

        // --- Post-deploy verification: read back the immutable to confirm we deployed OUR code ---
        require(
            address(SafeAssetRecoveryModule(module).etherFiDataProvider()) == dataProvider,
            "VERIFY FAILED: dataProvider mismatch"
        );

        bytes32 codeHash = keccak256(module.code);
        console.log("SafeAssetRecoveryModule : %s", module);
        console.log("DataProvider            : %s", dataProvider);
        console.log("Runtime bytecode hash (for independent verification):");
        console.logBytes32(codeHash);

        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes memory whitelistCalldata = abi.encodeCall(
            EtherFiDataProvider.configureDefaultModules,
            (modules, shouldWhitelist)
        );
        console.log("");
        console.log("3CP calldata - operating safe signs on OP:");
        console.log("  target  : %s (EtherFiDataProvider)", dataProvider);
        console.log("  method  : configureDefaultModules([%s], [true])", module);
        console.log("  calldata:");
        console.logBytes(whitelistCalldata);
    }
}
