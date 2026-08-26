// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { SafeAssetRecoveryModule } from "../../src/modules/recovery/SafeAssetRecoveryModule.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @notice Verifies the deployed SafeAssetRecoveryModule's runtime bytecode matches a local build
 *         from this source with the same constructor arg. Reads the module + dataProvider from
 *         deployments.json (update it to the new address first). On prod, also requires the
 *         address to equal the CREATE3 v2 prediction.
 *
 * Usage (read-only, no broadcast):
 *   forge script scripts/recovery/VerifySafeRecoveryModuleBytecode.s.sol --rpc-url $OPTIMISM_RPC
 *   ENV=mainnet forge script scripts/recovery/VerifySafeRecoveryModuleBytecode.s.sol --rpc-url $OPTIMISM_RPC
 */
contract VerifySafeRecoveryModuleBytecode is Utils, RecoveryDeployHelper, ContractCodeChecker {
    function run() external {
        require(block.chainid == 10, "must be Optimism");

        string memory deployments = readDeploymentFile();
        
        address module = 0x7abdECa95d0e81bDECE2C055EE8D1a5b5bFb18E2;

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        require(dataProvider != address(0), "EtherFiDataProvider not found");
        require(module.code.length > 0, "no code at module address");

        if (isEqualString(getEnv(), "mainnet")) {
            require(
                module == _predictImpl(RecoveryDeployConfig.SALT_SAFE_RECOVERY_MODULE_V2),
                "module address != CREATE3 v2 prediction"
            );
        }

        require(
            address(SafeAssetRecoveryModule(module).etherFiDataProvider()) == dataProvider,
            "dataProvider immutable mismatch"
        );
        address localRef = address(new SafeAssetRecoveryModule(dataProvider));
        verifyContractByteCodeMatch(module, localRef);

        console.log("[OK] %s bytecode matches local build (dataProvider %s)", module, dataProvider);
    }
}
