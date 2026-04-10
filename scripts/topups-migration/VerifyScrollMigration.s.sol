// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { MigrationBridgeModule } from "../../src/migration/MigrationBridgeModule.sol";
import { TopUpDestWithMigration } from "../../src/top-up/TopUpDestWithMigration.sol";
import { DebtManagerCoreWithMigration } from "../../src/debt-manager/DebtManagerCoreWithMigration.sol";
import { CashLensWithMigration } from "../../src/modules/cash/CashLensWithMigration.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title VerifyScrollMigration
 * @notice Post-deployment verification for the full Scroll migration stack.
 *         Reverts on ANY failed check so CI/wrappers can rely on exit code.
 *
 *         If the gnosis bundle has not been executed yet, the script will simulate
 *         it on a fork before running verification checks.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/topups-migration/VerifyScrollMigration.s.sol --rpc-url $SCROLL_RPC
 */
contract VerifyScrollMigration is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant WETH = 0x5300000000000000000000000000000000000004;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT      = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Must match DeployScrollMigration.s.sol salts exactly
    bytes32 constant SALT_MIGRATION_MODULE_IMPL  = keccak256("TopupsMigration.Prod.MigrationModuleImpl");
    bytes32 constant SALT_MIGRATION_MODULE_PROXY = keccak256("TopupsMigration.Prod.MigrationModuleProxy");
    bytes32 constant SALT_HOOK_IMPL              = keccak256("TopupsMigration.Prod.HookImpl");
    bytes32 constant SALT_TOPUP_DEST_IMPL        = keccak256("TopupsMigration.Prod.TopUpDestWithMigrationImpl");
    bytes32 constant SALT_DEBT_MANAGER_IMPL      = keccak256("TopupsMigration.Prod.DebtManagerCoreWithMigrationImpl");
    bytes32 constant SALT_CASH_LENS_IMPL         = keccak256("TopupsMigration.Prod.CashLensWithMigrationImpl");

    struct Addrs {
        address dataProvider;
        address hook;
        address topUpDest;
        address debtManager;
        address cashLens;
        address cashModule;
        address roleRegistry;
    }

    function run() public {
        require(block.chainid == 534352, "Must run on Scroll (534352)");

        Addrs memory a = _loadAddrs();
        address expectedMigrationProxy = CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_PROXY, NICKS_FACTORY);

        console.log("=============================================");
        console.log("  Verify Scroll Migration (Post-Deploy)");
        console.log("=============================================");

        // If gnosis bundle hasn't been executed yet, simulate it on fork
        _simulateGnosisBundleIfNeeded(a);

        _verifyExistence();
        _verifyImplSlots(a, expectedMigrationProxy);
        _verifyInitialization(expectedMigrationProxy);
        _verifyImmutables(a, expectedMigrationProxy);
        _verifyHookAndModule(a, expectedMigrationProxy);
        _verifyRolesAndConfig(a, expectedMigrationProxy);
        _verifyFunctional(a, expectedMigrationProxy);
        _verifyOwnership(a);

        console.log("\n=============================================");
        console.log("  ALL CHECKS PASSED");
        console.log("=============================================");
    }

    function _loadAddrs() internal view returns (Addrs memory a) {
        string memory deployments = readDeploymentFile();
        a.dataProvider  = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        a.hook          = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        a.topUpDest     = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        a.debtManager   = stdJson.readAddress(deployments, ".addresses.DebtManager");
        a.cashLens      = stdJson.readAddress(deployments, ".addresses.CashLens");
        a.cashModule    = stdJson.readAddress(deployments, ".addresses.CashModule");
        a.roleRegistry  = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
    }

    function _verifyExistence() internal view {
        console.log("\n--- 1. Contract existence ---");
        address[6] memory addrs = [
            CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_IMPL, NICKS_FACTORY),
            CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_PROXY, NICKS_FACTORY),
            CREATE3.predictDeterministicAddress(SALT_HOOK_IMPL, NICKS_FACTORY),
            CREATE3.predictDeterministicAddress(SALT_TOPUP_DEST_IMPL, NICKS_FACTORY),
            CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_IMPL, NICKS_FACTORY),
            CREATE3.predictDeterministicAddress(SALT_CASH_LENS_IMPL, NICKS_FACTORY)
        ];
        for (uint256 i = 0; i < addrs.length; i++) {
            require(addrs[i].code.length > 0, "CREATE3 contract has no code");
        }
        console.log("  [OK] All 6 CREATE3 contracts deployed");
    }

    function _verifyImplSlots(Addrs memory a, address expectedMigrationProxy) internal view {
        console.log("\n--- 2. EIP-1967 impl slots ---");

        address expectedMigrationImpl = CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_IMPL, NICKS_FACTORY);
        address actual = address(uint160(uint256(vm.load(expectedMigrationProxy, EIP1967_IMPL_SLOT))));
        require(actual == expectedMigrationImpl, "MigrationBridgeModule impl mismatch");
        console.log("  [OK] MigrationBridgeModule proxy -> impl");

        address expectedHookImpl = CREATE3.predictDeterministicAddress(SALT_HOOK_IMPL, NICKS_FACTORY);
        actual = address(uint160(uint256(vm.load(a.hook, EIP1967_IMPL_SLOT))));
        require(actual == expectedHookImpl, "EtherFiHook impl mismatch");
        console.log("  [OK] EtherFiHook -> impl");

        address expectedTopUpDestImpl = CREATE3.predictDeterministicAddress(SALT_TOPUP_DEST_IMPL, NICKS_FACTORY);
        actual = address(uint160(uint256(vm.load(a.topUpDest, EIP1967_IMPL_SLOT))));
        require(actual == expectedTopUpDestImpl, "TopUpDest impl mismatch");
        console.log("  [OK] TopUpDest -> impl");

        address expectedDebtMgrImpl = CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_IMPL, NICKS_FACTORY);
        actual = address(uint160(uint256(vm.load(a.debtManager, EIP1967_IMPL_SLOT))));
        require(actual == expectedDebtMgrImpl, "DebtManager impl mismatch");
        console.log("  [OK] DebtManager -> impl");

        address expectedCashLensImpl = CREATE3.predictDeterministicAddress(SALT_CASH_LENS_IMPL, NICKS_FACTORY);
        actual = address(uint160(uint256(vm.load(a.cashLens, EIP1967_IMPL_SLOT))));
        require(actual == expectedCashLensImpl, "CashLens impl mismatch");
        console.log("  [OK] CashLens -> impl");
    }

    function _verifyInitialization(address migrationProxy) internal view {
        console.log("\n--- 3. Initialization ---");
        uint256 initSlot = uint256(vm.load(migrationProxy, OZ_INIT_SLOT));
        require(initSlot > 0, "MigrationBridgeModule proxy NOT initialized");
        console.log("  [OK] MigrationBridgeModule initialized");
    }

    function _verifyImmutables(Addrs memory a, address migrationProxy) internal view {
        console.log("\n--- 4. Immutables ---");

        MigrationBridgeModule migration = MigrationBridgeModule(payable(migrationProxy));
        require(address(migration.dataProvider()) == a.dataProvider, "Migration: dataProvider mismatch");
        require(address(migration.topUpDest()) == a.topUpDest, "Migration: topUpDest mismatch");
        console.log("  [OK] Migration immutables correct");

        TopUpDestWithMigration topUpDest = TopUpDestWithMigration(payable(a.topUpDest));
        require(topUpDest.migrationModule() == migrationProxy, "TopUpDest: migrationModule mismatch");
        console.log("  [OK] TopUpDest.migrationModule correct");

        DebtManagerCoreWithMigration dm = DebtManagerCoreWithMigration(a.debtManager);
        require(address(dm.topUpDest()) == a.topUpDest, "DebtManager: topUpDest mismatch");
        console.log("  [OK] DebtManager.topUpDest correct");

        CashLensWithMigration cl = CashLensWithMigration(a.cashLens);
        require(address(cl.topUpDest()) == a.topUpDest, "CashLens: topUpDest mismatch");
        console.log("  [OK] CashLens.topUpDest correct");
    }

    function _verifyHookAndModule(Addrs memory a, address migrationProxy) internal view {
        console.log("\n--- 5-6. Hook and module ---");

        EtherFiHook hook = EtherFiHook(a.hook);
        require(hook.migrationModule() == migrationProxy, "Hook migrationModule mismatch");
        console.log("  [OK] Hook.migrationModule set");

        EtherFiDataProvider dp = EtherFiDataProvider(a.dataProvider);
        require(dp.isDefaultModule(migrationProxy), "Not registered as default module");
        console.log("  [OK] Migration registered as default module");
    }

    function _verifyRolesAndConfig(Addrs memory a, address migrationProxy) internal view {
        console.log("\n--- 7-8. Config and roles ---");

        MigrationBridgeModule migration = MigrationBridgeModule(payable(migrationProxy));
        address[] memory tokens = migration.getTokens();
        require(tokens.length == 17, "Expected 17 tokens configured");
        console.log("  [OK] 17 tokens configured");

        RoleRegistry rr = RoleRegistry(a.roleRegistry);
        bytes32 adminRole = migration.MIGRATION_BRIDGE_ADMIN_ROLE();
        require(rr.hasRole(adminRole, CASH_CONTROLLER_SAFE), "MIGRATION_BRIDGE_ADMIN_ROLE not granted");
        console.log("  [OK] MIGRATION_BRIDGE_ADMIN_ROLE granted");
    }

    function _verifyFunctional(Addrs memory a, address migrationProxy) internal view {
        console.log("\n--- 9-11. Functional checks ---");
        migrationProxy; // silence unused warning

        TopUpDestWithMigration topUpDest = TopUpDestWithMigration(payable(a.topUpDest));
        require(!topUpDest.isMigrated(address(1)), "isMigrated should return false");
        console.log("  [OK] TopUpDest.isMigrated() functional");

        require(address(DebtManagerCoreWithMigration(a.debtManager).topUpDest()) != address(0), "DebtManager topUpDest is zero");
        console.log("  [OK] DebtManager.topUpDest() functional");

        require(address(CashLensWithMigration(a.cashLens).topUpDest()) != address(0), "CashLens topUpDest is zero");
        console.log("  [OK] CashLens.topUpDest() functional");
    }

    function _verifyOwnership(Addrs memory a) internal view {
        console.log("\n--- 12. Ownership ---");
        address currentOwner = RoleRegistry(a.roleRegistry).owner();
        require(currentOwner == CASH_CONTROLLER_SAFE, "RoleRegistry owner changed - possible hijack");
        console.log("  [OK] RoleRegistry owner:", currentOwner);
    }

    /// @dev If the gnosis bundle hasn't been executed on-chain yet, simulate it on the fork.
    ///      Detection: check if the hook's migrationModule is already set to the expected proxy.
    function _simulateGnosisBundleIfNeeded(Addrs memory a) internal {
        address expectedMigrationProxy = CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_PROXY, NICKS_FACTORY);
        EtherFiHook hook = EtherFiHook(a.hook);

        try hook.migrationModule() returns (address migrationModule) {
            if (migrationModule == expectedMigrationProxy) {
                console.log("\n[INFO] Gnosis bundle already executed on-chain, skipping simulation");
                return;
            }
        } catch {
            // If the hook doesn't have a migrationModule, gnosis bundle was not executed
        }

        console.log("\n[INFO] Gnosis bundle NOT yet executed, simulating on fork...");
        string memory path = "./output/DeployScrollMigration.json";
        require(vm.exists(path), "Gnosis bundle not found at ./output/DeployScrollMigration.json - run DeployScrollMigration first");
        executeGnosisTransactionBundle(path);
        console.log("[OK] Gnosis bundle simulation complete");
    }
}
