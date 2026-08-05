// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../../../src/interfaces/IRoleRegistry.sol";
import { SafeAssetRecoveryModule } from "../../../src/modules/recovery/SafeAssetRecoveryModule.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice DEV-ONLY. Deploys SafeAssetRecoveryModule on Optimism without CREATE3 so dev addresses
 *         don't collide with the prod CREATE3 slot. The deployer EOA grants itself the
 *         DATA_PROVIDER_ADMIN_ROLE (it is the dev RoleRegistry owner) and whitelists the module.
 *         Mirrors DeployRecoveryDevOp.s.sol, minus all LayerZero machinery.
 *
 * Env:
 *   ENV=dev       — required so Utils reads from deployments/dev/10/
 *   PRIVATE_KEY   — deployer key (must be RoleRegistry owner on dev OP)
 */
contract DeploySafeRecoveryDevOp is Utils {
    function run() external {
        require(block.chainid == 10, "must be Optimism");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        require(dataProvider != address(0), "EtherFiDataProvider missing");
        require(roleRegistry != address(0), "RoleRegistry missing");

        bytes32 adminRole = EtherFiDataProvider(dataProvider).DATA_PROVIDER_ADMIN_ROLE();

        vm.startBroadcast(deployerPk);

        if (!IRoleRegistry(roleRegistry).hasRole(adminRole, deployer)) {
            IRoleRegistry(roleRegistry).grantRole(adminRole, deployer);
        }

        SafeAssetRecoveryModule module = new SafeAssetRecoveryModule(dataProvider);

        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        // Register as a DEFAULT module (whitelists + marks default in one call), matching how every
        // other fund-moving module (CashModule, swap, liquid) is registered. It is then enabled on
        // every safe automatically, so no per-safe enable / extra signature is needed.
        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, whitelist);

        vm.stopBroadcast();

        console.log("=== Dev OP SafeAssetRecoveryModule deployed (default module) ===");
        console.log("SafeAssetRecoveryModule : %s", address(module));
        console.log("DataProvider            : %s", dataProvider);
        console.log("RoleRegistry            : %s", roleRegistry);
        console.log("Deployer                : %s (EOA)", deployer);
        console.log("");
        console.log("Registered as a default module, enabled on all safes, no per-safe enable needed.");
    }
}
