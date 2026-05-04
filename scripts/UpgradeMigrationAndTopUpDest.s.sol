// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { MigrationBridgeModule } from "../src/migration/MigrationBridgeModule.sol";
import { TopUpDestWithMigration } from "../src/top-up/TopUpDestWithMigration.sol";
import { Utils } from "./utils/Utils.sol";

/// @title UpgradeMigrationAndTopUpDest
/// @notice Deploys and upgrades MigrationBridgeModule and TopUpDestWithMigration on Scroll.
///         - Deploys new MigrationBridgeModule impl (with TopUpDest address)
///         - Upgrades MigrationBridgeModule proxy
///         - Deploys TopUpDestWithMigration impl (with migration module address)
///         - Upgrades TopUpDest proxy to TopUpDestWithMigration
///         - Registers migration module as default module + sets it on the hook
///
/// Usage:
///   ENV=dev PRIVATE_KEY=0x... forge script scripts/UpgradeMigrationAndTopUpDest.s.sol --rpc-url <SCROLL_RPC> --broadcast
contract UpgradeMigrationAndTopUpDest is Utils {

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address topUpDestProxy = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        address migrationModuleProxy = stdJson.readAddress(deployments, ".addresses.MigrationBridgeModule");

        console.log("DataProvider:", dataProvider);
        console.log("TopUpDest proxy:", topUpDestProxy);
        console.log("MigrationBridgeModule proxy:", migrationModuleProxy);

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. Deploy new MigrationBridgeModule impl (with topUpDest) ──
        console.log("1. Deploying MigrationBridgeModule impl...");
        address migrationImpl = address(new MigrationBridgeModule(dataProvider, topUpDestProxy));
        console.log("   impl:", migrationImpl);

        // ── 2. Upgrade MigrationBridgeModule proxy ──
        console.log("2. Upgrading MigrationBridgeModule proxy...");
        UUPSUpgradeable(migrationModuleProxy).upgradeToAndCall(migrationImpl, "");

        // ── 3. Deploy TopUpDestWithMigration impl (with migration module) ──
        console.log("3. Deploying TopUpDestWithMigration impl...");
        address topUpDestV2Impl = address(new TopUpDestWithMigration(dataProvider, migrationModuleProxy));
        console.log("   impl:", topUpDestV2Impl);

        // ── 4. Upgrade TopUpDest proxy to TopUpDestWithMigration ──
        console.log("4. Upgrading TopUpDest proxy...");
        UUPSUpgradeable(topUpDestProxy).upgradeToAndCall(topUpDestV2Impl, "");

        vm.stopBroadcast();

        // ── Verify ──
        console.log("\n=== Verification ===");
        require(TopUpDestWithMigration(topUpDestProxy).migrationModule() == migrationModuleProxy, "TopUpDest migration module mismatch");
        console.log("[OK] TopUpDest.migrationModule =", migrationModuleProxy);

        require(MigrationBridgeModule(payable(migrationModuleProxy)).topUpDest() == TopUpDestWithMigration(topUpDestProxy), "Migration topUpDest mismatch");
        console.log("[OK] MigrationBridgeModule.topUpDest =", topUpDestProxy);

        console.log("\n[OK] All upgrades complete");
        console.log("  MigrationBridgeModule impl:", migrationImpl);
        console.log("  TopUpDestWithMigration impl:", topUpDestV2Impl);
    }
}
