// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { MigrationBridgeModule } from "../../src/migration/MigrationBridgeModule.sol";
import { TopUpDestWithMigration } from "../../src/top-up/TopUpDestWithMigration.sol";
import { DebtManagerCoreWithMigration } from "../../src/debt-manager/DebtManagerCoreWithMigration.sol";
import { CashLensWithMigration } from "../../src/modules/cash/CashLensWithMigration.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";

/// @title VerifyScrollMigrationBytecode
/// @notice Deploys all Scroll migration contracts locally and compares bytecode
///         against the on-chain CREATE3-deployed impls. Also verifies all proxy
///         EIP-1967 impl slots point to the expected CREATE3 addresses.
///
///         If the gnosis bundle hasn't been executed yet, simulates it on fork first.
///
///         NOTE: UUPS contracts embed their own address in bytecode for the proxy check.
///         The only expected mismatches are the 3 self-reference segments per contract
///         (local address vs on-chain address). Length match + all other bytes matching
///         confirms the code is correct.
///
/// Usage:
///   ENV=mainnet forge script scripts/topups-migration/VerifyScrollMigrationBytecode.s.sol \
///     --rpc-url $SCROLL_RPC -vvv
contract VerifyScrollMigrationBytecode is Script, ContractCodeChecker, GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant WETH = 0x5300000000000000000000000000000000000004;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Must match DeployScrollMigration.s.sol salts exactly
    bytes32 constant SALT_MIGRATION_MODULE_IMPL  = keccak256("TopupsMigration.Prod.MigrationModuleImpl");
    bytes32 constant SALT_MIGRATION_MODULE_PROXY = keccak256("TopupsMigration.Prod.MigrationModuleProxy");
    bytes32 constant SALT_HOOK_IMPL              = keccak256("TopupsMigration.Prod.HookImpl");
    bytes32 constant SALT_TOPUP_DEST_IMPL        = keccak256("TopupsMigration.Prod.TopUpDestWithMigrationImpl");
    bytes32 constant SALT_DEBT_MANAGER_IMPL      = keccak256("TopupsMigration.Prod.DebtManagerCoreWithMigrationImpl");
    bytes32 constant SALT_CASH_LENS_IMPL         = keccak256("TopupsMigration.Prod.CashLensWithMigrationImpl");

    function run() public {
        require(block.chainid == 534352, "Must run on Scroll (534352)");

        string memory deployments = readDeploymentFile();
        address dataProvider  = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address topUpDest     = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        address hookProxy     = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        address debtMgrProxy  = stdJson.readAddress(deployments, ".addresses.DebtManager");
        address cashLensProxy = stdJson.readAddress(deployments, ".addresses.CashLens");
        address cashModule    = stdJson.readAddress(deployments, ".addresses.CashModule");

        address migrationProxy = CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_PROXY, NICKS_FACTORY);

        console2.log("=============================================");
        console2.log("  Scroll Migration Bytecode Verification");
        console2.log("=============================================\n");

        // ── 1. MigrationBridgeModule impl ──
        {
            address deployedImpl = CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_IMPL, NICKS_FACTORY);
            console2.log("1. MigrationBridgeModule impl (%s)", deployedImpl);
            address localImpl = address(new MigrationBridgeModule(dataProvider, topUpDest));
            verifyContractByteCodeMatch(deployedImpl, localImpl);
        }

        // ── 2. EtherFiHook impl ──
        {
            address deployedImpl = CREATE3.predictDeterministicAddress(SALT_HOOK_IMPL, NICKS_FACTORY);
            console2.log("2. EtherFiHook impl (%s)", deployedImpl);
            address localImpl = address(new EtherFiHook(dataProvider));
            verifyContractByteCodeMatch(deployedImpl, localImpl);
        }

        // ── 3. TopUpDestWithMigration impl ──
        {
            address deployedImpl = CREATE3.predictDeterministicAddress(SALT_TOPUP_DEST_IMPL, NICKS_FACTORY);
            console2.log("3. TopUpDestWithMigration impl (%s)", deployedImpl);
            address localImpl = address(new TopUpDestWithMigration(dataProvider, WETH, migrationProxy));
            verifyContractByteCodeMatch(deployedImpl, localImpl);
        }

        // ── 4. DebtManagerCoreWithMigration impl ──
        {
            address deployedImpl = CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_IMPL, NICKS_FACTORY);
            console2.log("4. DebtManagerCoreWithMigration impl (%s)", deployedImpl);
            address localImpl = address(new DebtManagerCoreWithMigration(dataProvider, topUpDest));
            verifyContractByteCodeMatch(deployedImpl, localImpl);
        }

        // ── 5. CashLensWithMigration impl ──
        {
            address deployedImpl = CREATE3.predictDeterministicAddress(SALT_CASH_LENS_IMPL, NICKS_FACTORY);
            console2.log("5. CashLensWithMigration impl (%s)", deployedImpl);
            address localImpl = address(new CashLensWithMigration(cashModule, dataProvider, topUpDest));
            verifyContractByteCodeMatch(deployedImpl, localImpl);
        }

        // ── 6. Simulate gnosis bundle if not yet executed ──
        {
            address expectedHookImpl = CREATE3.predictDeterministicAddress(SALT_HOOK_IMPL, NICKS_FACTORY);
            address actualHookImpl = address(uint160(uint256(vm.load(hookProxy, EIP1967_IMPL_SLOT))));
            if (actualHookImpl != expectedHookImpl) {
                console2.log("6. Gnosis bundle NOT yet executed, simulating on fork...");
                string memory path = "./output/DeployScrollMigration.json";
                require(vm.exists(path), "Gnosis bundle not found - run DeployScrollMigration first");
                executeGnosisTransactionBundle(path);
                console2.log("   [OK] Gnosis bundle simulation complete\n");
            } else {
                console2.log("6. Gnosis bundle already executed on-chain\n");
            }
        }

        // ── 7. Verify proxy impl slots ──
        console2.log("7. Verifying proxy impl slots...");
        _verifyImplSlot("MigrationBridgeModule", migrationProxy, SALT_MIGRATION_MODULE_IMPL);
        _verifyImplSlot("EtherFiHook", hookProxy, SALT_HOOK_IMPL);
        _verifyImplSlot("TopUpDest", topUpDest, SALT_TOPUP_DEST_IMPL);
        _verifyImplSlot("DebtManager", debtMgrProxy, SALT_DEBT_MANAGER_IMPL);
        _verifyImplSlot("CashLens", cashLensProxy, SALT_CASH_LENS_IMPL);

        console2.log("\n=============================================");
        console2.log("  ALL CHECKS PASSED");
        console2.log("=============================================");
    }

    function _verifyImplSlot(string memory label, address proxy, bytes32 implSalt) internal view {
        address expectedImpl = CREATE3.predictDeterministicAddress(implSalt, NICKS_FACTORY);
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(
            actualImpl == expectedImpl,
            string.concat(label, " impl mismatch - expected ", vm.toString(expectedImpl), " got ", vm.toString(actualImpl))
        );
        console2.log("  [OK]", label, "-> impl", actualImpl);
    }
}
