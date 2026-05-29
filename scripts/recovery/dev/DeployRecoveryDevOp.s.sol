// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../../../src/interfaces/IRoleRegistry.sol";
import { AssetRecoveryModule } from "../../../src/modules/recovery/AssetRecoveryModule.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice DEV-ONLY. Deploys AssetRecoveryModule on Optimism without CREATE3 so dev addresses
 *         don't collide with the prod CREATE3 slot. Deployer EOA is used as both the OApp
 *         delegate and the operating-safe stand-in (so `setPeer`, `pause`, etc. can be called
 *         directly with PRIVATE_KEY).
 *
 * Env:
 *   ENV=dev       — required so Utils reads from deployments/dev/10/
 *   PRIVATE_KEY   — deployer key (must be RoleRegistry owner on dev OP)
 *   LZ_ENDPOINT   — LayerZero v2 endpoint on OP (0x1a44076050125825900e736c501f859c50fE728c)
 */
contract DeployRecoveryDevOp is Utils {
    function run() external {
        require(block.chainid == 10, "must be Optimism");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");

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

        AssetRecoveryModule module = new AssetRecoveryModule(dataProvider, lzEndpoint, deployer);

        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        EtherFiDataProvider(dataProvider).configureModules(modules, whitelist);

        vm.stopBroadcast();

        console.log("=== Dev OP recovery module deployed ===");
        console.log("AssetRecoveryModule : %s", address(module));
        console.log("DataProvider        : %s", dataProvider);
        console.log("RoleRegistry        : %s", roleRegistry);
        console.log("LZ endpoint         : %s", lzEndpoint);
        console.log("Owner / delegate    : %s (deployer EOA)", deployer);
        console.log("");
        console.log("Pass MODULE_OP=%s into DeployRecoveryDevDest", address(module));
    }
}
