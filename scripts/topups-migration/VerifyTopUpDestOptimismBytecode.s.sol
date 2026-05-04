// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";

/// @title VerifyTopUpDestOptimismBytecode
/// @notice Deploys TopUpDest locally and compares bytecode against the on-chain
///         CREATE3-deployed impl on OP Mainnet. Also verifies the proxy impl slot.
///         If the gnosis bundle hasn't been executed yet, simulates it on fork first.
///
/// Usage:
///   ENV=mainnet forge script scripts/topups-migration/VerifyTopUpDestOptimismBytecode.s.sol \
///     --rpc-url $OPTIMISM_RPC -vvv
contract VerifyTopUpDestOptimismBytecode is Script, ContractCodeChecker, GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant OP_WETH = 0x4200000000000000000000000000000000000006;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Must match UpgradeTopUpDestOptimism.s.sol
    bytes32 constant SALT_TOPUP_DEST_IMPL = keccak256("TopupsMigration.Prod.TopUpDestOptimismImpl");

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (10)");

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address topUpDestProxy = stdJson.readAddress(deployments, ".addresses.TopUpDest");

        address deployedImpl = CREATE3.predictDeterministicAddress(SALT_TOPUP_DEST_IMPL, NICKS_FACTORY);

        console2.log("=============================================");
        console2.log("  TopUpDest Optimism Bytecode Verification");
        console2.log("=============================================\n");

        // 1. Verify impl bytecode
        console2.log("1. TopUpDest impl (%s)", deployedImpl);
        address localImpl = address(new TopUpDest(dataProvider, OP_WETH));
        verifyContractByteCodeMatch(deployedImpl, localImpl);

        // 2. Simulate gnosis bundle if not yet executed
        {
            address currentImpl = address(uint160(uint256(vm.load(topUpDestProxy, EIP1967_IMPL_SLOT))));
            if (currentImpl != deployedImpl) {
                console2.log("2. Gnosis bundle NOT yet executed, simulating on fork...");
                string memory path = string.concat("./output/UpgradeTopUpDestOptimism-", vm.toString(block.chainid), ".json");
                require(vm.exists(path), "Gnosis bundle not found - run UpgradeTopUpDestOptimism first");
                executeGnosisTransactionBundle(path);
                console2.log("   [OK] Gnosis bundle simulation complete\n");
            } else {
                console2.log("2. Gnosis bundle already executed on-chain\n");
            }
        }

        // 3. Verify proxy impl slot
        console2.log("3. Verifying proxy impl slot...");
        address actualImpl = address(uint160(uint256(vm.load(topUpDestProxy, EIP1967_IMPL_SLOT))));
        require(
            actualImpl == deployedImpl,
            string.concat("TopUpDest impl mismatch - expected ", vm.toString(deployedImpl), " got ", vm.toString(actualImpl))
        );
        console2.log("  [OK] TopUpDest -> impl", actualImpl);

        console2.log("\n=============================================");
        console2.log("  ALL CHECKS PASSED");
        console2.log("=============================================");
    }
}
