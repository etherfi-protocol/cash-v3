// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title VerifyTopUpDestOptimism
 * @notice Post-deployment verification for the TopUpDest upgrade on OP Mainnet.
 *         If the gnosis bundle hasn't been executed yet, simulates it on fork first.
 *         Reverts on any failed check.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/topups-migration/VerifyTopUpDestOptimism.s.sol --rpc-url $OPTIMISM_RPC
 */
contract VerifyTopUpDestOptimism is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant OP_WETH = 0x4200000000000000000000000000000000000006;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT      = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Must match UpgradeTopUpDestOptimism.s.sol
    bytes32 constant SALT_TOPUP_DEST_IMPL = keccak256("TopupsMigration.Prod.TopUpDestOptimismImpl");

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (10)");

        string memory deployments = readDeploymentFile();
        address dataProviderAddr = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address topUpDestProxy   = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        address expectedImpl = CREATE3.predictDeterministicAddress(SALT_TOPUP_DEST_IMPL, NICKS_FACTORY);

        console.log("=============================================");
        console.log("  Verify TopUpDest Optimism (Post-Deploy)");
        console.log("=============================================");
        console.log("Chain ID:", block.chainid);
        console.log("Expected impl:", expectedImpl);
        console.log("TopUpDest proxy:", topUpDestProxy);

        // Simulate gnosis bundle if not yet executed
        {
            address actualImpl = address(uint160(uint256(vm.load(topUpDestProxy, EIP1967_IMPL_SLOT))));
            if (actualImpl != expectedImpl) {
                console.log("\n[INFO] Gnosis bundle NOT yet executed, simulating on fork...");
                string memory path = string.concat("./output/UpgradeTopUpDestOptimism-", vm.toString(block.chainid), ".json");
                require(vm.exists(path), "Gnosis bundle not found - run UpgradeTopUpDestOptimism first");
                executeGnosisTransactionBundle(path);
                console.log("[OK] Gnosis bundle simulation complete");
            } else {
                console.log("\n[INFO] Gnosis bundle already executed on-chain");
            }
        }

        // ── 1. Contract existence ──
        console.log("\n--- 1. Contract existence ---");
        require(expectedImpl.code.length > 0, "TopUpDest impl has no code");
        require(topUpDestProxy.code.length > 0, "TopUpDest proxy has no code");
        console.log("  [OK] Impl and proxy deployed");

        // ── 2. EIP-1967 impl slot ──
        console.log("\n--- 2. Impl slot ---");
        address actualImpl = address(uint160(uint256(vm.load(topUpDestProxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "TopUpDest impl mismatch - possible hijack");
        console.log("  [OK] TopUpDest -> impl:", actualImpl);

        // ── 3. Initialization ──
        console.log("\n--- 3. Initialization ---");
        uint256 initSlot = uint256(vm.load(topUpDestProxy, OZ_INIT_SLOT));
        require(initSlot > 0, "TopUpDest NOT initialized");
        console.log("  [OK] Initialized (v=%s)", vm.toString(initSlot));

        // ── 4. Immutables ──
        console.log("\n--- 4. Immutables ---");
        TopUpDest topUpDest = TopUpDest(payable(topUpDestProxy));
        require(address(topUpDest.etherFiDataProvider()) == dataProviderAddr, "dataProvider mismatch");
        require(address(topUpDest.weth()) == OP_WETH, "WETH mismatch");
        console.log("  [OK] dataProvider:", dataProviderAddr);
        console.log("  [OK] WETH:", OP_WETH);

        // ── 5. Ownership ──
        console.log("\n--- 6. Ownership ---");
        address currentOwner = RoleRegistry(roleRegistryAddr).owner();
        require(currentOwner == CASH_CONTROLLER_SAFE, "RoleRegistry owner changed - possible hijack");
        console.log("  [OK] RoleRegistry owner:", currentOwner);

        console.log("\n=============================================");
        console.log("  ALL CHECKS PASSED");
        console.log("=============================================");
    }
}
