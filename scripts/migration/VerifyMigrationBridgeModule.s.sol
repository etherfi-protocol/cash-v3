// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { MigrationBridgeModule } from "../../src/migration/MigrationBridgeModule.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title VerifyMigrationBridgeModule
 * @notice Post-deployment verification for MigrationBridgeModule.
 *         Reverts on any failed check so CI/scripts can rely on exit code.
 *         Works for both dev and prod — run AFTER all txs confirm (including gnosis bundle).
 *
 * Verifies:
 *   1-3. Contract existence + EIP-1967 impl slots match CREATE3 predictions
 *   4.   Proxy initialized
 *   5.   Hook migration module bypass set
 *   6.   Registered as default module on DataProvider
 *   7.   Immutable dataProvider correct
 *   8.   17 tokens configured
 *   9.   MIGRATION_BRIDGE_ADMIN_ROLE granted
 *   10.  RoleRegistry owner unchanged (catches hijack in gnosis batch)
 *
 * Usage:
 *   ENV=dev     forge script scripts/migration/VerifyMigrationBridgeModule.s.sol --rpc-url $SCROLL_RPC
 *   ENV=mainnet forge script scripts/migration/VerifyMigrationBridgeModule.s.sol --rpc-url $SCROLL_RPC
 */
contract VerifyMigrationBridgeModule is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant OWNER_DEV = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address constant OWNER_PROD = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT      = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Dev salts (must match scripts/migration/DeployMigrationBridgeModule.s.sol)
    bytes32 constant SALT_DEV_IMPL   = keccak256("MigrationBridgeModule.Dev.Impl");
    bytes32 constant SALT_DEV_PROXY  = keccak256("MigrationBridgeModule.Dev.Proxy");
    bytes32 constant SALT_DEV_HOOK   = keccak256("MigrationBridgeModule.Dev.HookImpl");

    // Prod salts (must match scripts/gnosis-txs/DeployMigrationBridgeModule.s.sol)
    bytes32 constant SALT_PROD_IMPL  = keccak256("MigrationBridgeModule.Prod.Impl");
    bytes32 constant SALT_PROD_PROXY = keccak256("MigrationBridgeModule.Prod.Proxy");
    bytes32 constant SALT_PROD_HOOK  = keccak256("MigrationBridgeModule.Prod.HookImpl");

    address owner;

    function run() public {
        string memory deployments = readDeploymentFile();
        address hookAddr = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        address dataProviderAddr = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        // Pick salts based on ENV
        bool isDev = isEqualString(getEnv(), "dev");
        bytes32 saltImpl  = isDev ? SALT_DEV_IMPL  : SALT_PROD_IMPL;
        bytes32 saltProxy = isDev ? SALT_DEV_PROXY  : SALT_PROD_PROXY;
        bytes32 saltHook  = isDev ? SALT_DEV_HOOK   : SALT_PROD_HOOK;
        owner = isDev ? OWNER_DEV : OWNER_PROD;

        address expectedImpl  = CREATE3.predictDeterministicAddress(saltImpl, NICKS_FACTORY);
        address expectedProxy = CREATE3.predictDeterministicAddress(saltProxy, NICKS_FACTORY);
        address expectedHookImpl = CREATE3.predictDeterministicAddress(saltHook, NICKS_FACTORY);

        console.log("=============================================");
        console.log("  Verify MigrationBridgeModule (Post-Deploy)");
        console.log("=============================================");
        console.log("Chain ID:", block.chainid);
        console.log("Expected impl: ", expectedImpl);
        console.log("Expected proxy:", expectedProxy);
        console.log("Expected hook: ", expectedHookImpl);
        console.log("");

        // ── 1. Contract existence ──
        console.log("--- 1. Contract existence ---");
        require(expectedImpl.code.length > 0, "Impl has no code");
        console.log("  [OK] Impl deployed");
        require(expectedProxy.code.length > 0, "Proxy has no code");
        console.log("  [OK] Proxy deployed");
        require(expectedHookImpl.code.length > 0, "Hook impl has no code");
        console.log("  [OK] Hook impl deployed");

        // ── 2. EIP-1967 impl slot matches CREATE3 prediction ──
        console.log("");
        console.log("--- 2. Proxy impl slot ---");
        address actualImpl = address(uint160(uint256(vm.load(expectedProxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "Proxy impl mismatch - possible hijack");
        console.log("  [OK] Proxy -> Impl:", actualImpl);

        // ── 3. Hook impl slot matches CREATE3 prediction ──
        console.log("");
        console.log("--- 3. Hook impl slot ---");
        address actualHookImpl = address(uint160(uint256(vm.load(hookAddr, EIP1967_IMPL_SLOT))));
        require(actualHookImpl == expectedHookImpl, "Hook impl mismatch - possible hijack");
        console.log("  [OK] Hook -> Impl:", actualHookImpl);

        // ── 4. Initialization ──
        console.log("");
        console.log("--- 4. Initialization ---");
        uint256 initSlot = uint256(vm.load(expectedProxy, OZ_INIT_SLOT));
        require(initSlot > 0, "Proxy NOT initialized");
        console.log("  [OK] Proxy initialized (v=", vm.toString(initSlot), ")");

        // ── 5. Hook migration module set correctly ──
        console.log("");
        console.log("--- 5. Hook migration bypass ---");
        EtherFiHook hook = EtherFiHook(hookAddr);
        require(hook.migrationModule() == expectedProxy, "Hook migrationModule mismatch");
        console.log("  [OK] Hook.migrationModule =", hook.migrationModule());

        // ── 6. Default module registration ──
        console.log("");
        console.log("--- 6. Default module ---");
        EtherFiDataProvider dp = EtherFiDataProvider(dataProviderAddr);
        require(dp.isDefaultModule(expectedProxy), "Not registered as default module");
        console.log("  [OK] Registered as default module");

        // ── 7. Immutables ──
        console.log("");
        console.log("--- 7. Immutables ---");
        MigrationBridgeModule module = MigrationBridgeModule(payable(expectedProxy));
        require(address(module.dataProvider()) == dataProviderAddr, "dataProvider mismatch");
        console.log("  [OK] dataProvider:", address(module.dataProvider()));

        // ── 8. Token config ──
        console.log("");
        console.log("--- 8. Token config ---");
        address[] memory tokens = module.getTokens();
        require(tokens.length == 17, "Expected 17 tokens configured");
        console.log("  [OK] 17 tokens configured");

        // ── 9. Admin role granted ──
        console.log("");
        console.log("--- 9. Admin role ---");
        RoleRegistry rr = RoleRegistry(roleRegistryAddr);
        bytes32 adminRole = module.MIGRATION_BRIDGE_ADMIN_ROLE();
        require(rr.hasRole(adminRole, owner), "MIGRATION_BRIDGE_ADMIN_ROLE not granted to OWNER");
        console.log("  [OK] MIGRATION_BRIDGE_ADMIN_ROLE granted to:", owner);

        // ── 10. RoleRegistry owner unchanged ──
        console.log("");
        console.log("--- 10. Ownership ---");
        address currentOwner = rr.owner();
        require(currentOwner == owner, "RoleRegistry owner changed - possible hijack");
        console.log("  [OK] RoleRegistry owner:", currentOwner);

        console.log("");
        console.log("=============================================");
        console.log("  ALL CHECKS PASSED");
        console.log("=============================================");
    }
}
