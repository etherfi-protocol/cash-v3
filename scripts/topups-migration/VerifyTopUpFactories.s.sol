// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title VerifyTopUpFactories
 * @notice Post-deployment verification for TopUpFactory upgrades on any source chain.
 *         If the gnosis bundle hasn't been executed yet, simulates it on fork first.
 *         Checks impl slot, adapter existence, token config, and ownership.
 *         Reverts on any failed check.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/topups-migration/VerifyTopUpFactories.s.sol --rpc-url <RPC>
 */
contract VerifyTopUpFactories is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();
        address factoryProxy = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        console.log("=============================================");
        console.log("  Verify TopUpFactory (Chain %s)", chainId);
        console.log("=============================================");
        console.log("TopUpFactory proxy:", factoryProxy);

        // Simulate gnosis bundle if not yet executed
        _simulateGnosisBundleIfNeeded(chainId, factoryProxy);

        // ── 1. Factory proxy exists ──
        console.log("\n--- 1. Factory existence ---");
        require(factoryProxy.code.length > 0, "Factory proxy has no code");
        console.log("  [OK] Factory proxy exists");

        // ── 2. Impl slot ──
        console.log("\n--- 2. Impl slot ---");
        bytes32 factorySalt = _getFactorySalt(chainId);
        address expectedFactoryImpl = CREATE3.predictDeterministicAddress(factorySalt, NICKS_FACTORY);
        address actualFactoryImpl = address(uint160(uint256(vm.load(factoryProxy, EIP1967_IMPL_SLOT))));
        require(actualFactoryImpl == expectedFactoryImpl, "Factory impl mismatch - possible hijack");
        console.log("  [OK] Factory -> impl:", actualFactoryImpl);

        // ── 3. Adapter existence ──
        console.log("\n--- 3. Adapter existence ---");
        _verifyAdapters(chainId);

        // ── 4. Token config check ──
        console.log("\n--- 4. Token configs ---");
        TopUpFactory factory = TopUpFactory(payable(factoryProxy));
        TopUpFactory.TokenConfig memory opConfig = factory.getTokenConfig(_getFirstTokenForChain(), 10);
        require(opConfig.bridgeAdapter != address(0), "No OP dest config found for spot-check token");
        console.log("  [OK] OP dest token config verified (adapter: %s)", opConfig.bridgeAdapter);

        // ── 5. Ownership ──
        console.log("\n--- 5. Ownership ---");
        address currentOwner = RoleRegistry(roleRegistryAddr).owner();
        require(currentOwner == CASH_CONTROLLER_SAFE, "RoleRegistry owner changed - possible hijack");
        console.log("  [OK] RoleRegistry owner:", currentOwner);

        console.log("\n=============================================");
        console.log("  ALL CHECKS PASSED");
        console.log("=============================================");
    }

    function _verifyAdapters(string memory chainId) internal view {
        if (block.chainid == 1) {
            _requireCode(keccak256("TopupsMigration.Prod.StargateAdapterEthereum"), "StargateAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.OptimismBridgeAdapterEthereum"), "OptimismBridgeAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.HopBridgeAdapterEthereum"), "HopBridgeAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.EtherFiLiquidBridgeAdapterEthereum"), "EtherFiLiquidBridgeAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterEthereum"), "EtherFiOFTBridgeAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.CCTPAdapterEthereum"), "CCTPAdapter");
        } else if (block.chainid == 8453) {
            _requireCode(keccak256("TopupsMigration.Prod.CCTPAdapterBase"), "CCTPAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.EtherFiLiquidBridgeAdapterBase"), "EtherFiLiquidBridgeAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterBase"), "EtherFiOFTBridgeAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.StargateAdapterBase"), "StargateAdapter");
        } else if (block.chainid == 999) {
            _requireCode(keccak256("TopupsMigration.Prod.CCTPAdapterHyperEVM"), "CCTPAdapter");
            _requireCode(keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterHyperEVM"), "EtherFiOFTBridgeAdapter");
        } else if (block.chainid == 42161) {
            _requireCode(keccak256("TopupsMigration.Prod.CCTPAdapterArbitrum"), "CCTPAdapter");
        } else {
            revert(string.concat("Unsupported chain: ", chainId));
        }
    }

    function _requireCode(bytes32 salt, string memory label) internal view {
        address addr = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);
        require(addr.code.length > 0, string.concat(label, " has no code"));
        console.log("  [OK] %s: %s", label, addr);
    }

    function _getFactorySalt(string memory chainId) internal view returns (bytes32) {
        if (block.chainid == 1)     return keccak256("TopupsMigration.Prod.TopUpFactoryEthereumImpl");
        if (block.chainid == 8453)  return keccak256("TopupsMigration.Prod.TopUpFactoryBaseImpl");
        if (block.chainid == 999)   return keccak256("TopupsMigration.Prod.TopUpFactoryHyperEVMImpl");
        if (block.chainid == 42161) return keccak256("TopupsMigration.Prod.TopUpFactoryArbitrumImpl");
        revert(string.concat("Unsupported chain: ", chainId));
    }

    function _simulateGnosisBundleIfNeeded(string memory chainId, address factoryProxy) internal {
        address expectedImpl = CREATE3.predictDeterministicAddress(_getFactorySalt(chainId), NICKS_FACTORY);
        address actualImpl = address(uint160(uint256(vm.load(factoryProxy, EIP1967_IMPL_SLOT))));
        if (actualImpl != expectedImpl) {
            console.log("\n[INFO] Gnosis bundle NOT yet executed, simulating on fork...");
            string memory path = _getGnosisBundlePath(chainId);
            require(vm.exists(path), string.concat("Gnosis bundle not found at ", path));
            executeGnosisTransactionBundle(path);
            console.log("[OK] Gnosis bundle simulation complete");
        } else {
            console.log("\n[INFO] Gnosis bundle already executed on-chain");
        }
    }

    function _getGnosisBundlePath(string memory chainId) internal view returns (string memory) {
        if (block.chainid == 1)     return string.concat("./output/UpgradeTopUpFactoryEthereum-", chainId, ".json");
        if (block.chainid == 8453)  return string.concat("./output/UpgradeTopUpFactoryBase-", chainId, ".json");
        if (block.chainid == 999)   return string.concat("./output/UpgradeTopUpFactoryHyperEVM-", chainId, ".json");
        if (block.chainid == 42161) return string.concat("./output/UpgradeTopUpFactoryArbitrum-", chainId, ".json");
        revert("Unsupported chain");
    }

    function _getFirstTokenForChain() internal view returns (address) {
        if (block.chainid == 1)     return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC (Ethereum)
        if (block.chainid == 8453)  return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC (Base)
        if (block.chainid == 999)   return 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // USDC (HyperEVM)
        if (block.chainid == 42161) return 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // USDC (Arbitrum)
        revert("Unsupported chain for spot-check");
    }
}
