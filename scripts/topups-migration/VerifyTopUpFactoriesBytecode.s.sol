// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StargateAdapter } from "../../src/top-up/bridge/StargateAdapter.sol";
import { OptimismBridgeAdapter } from "../../src/top-up/bridge/OptimismBridgeAdapter.sol";
import { HopBridgeAdapter } from "../../src/top-up/bridge/HopBridgeAdapter.sol";
import { EtherFiLiquidBridgeAdapter } from "../../src/top-up/bridge/EtherFiLiquidBridgeAdapter.sol";
import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import { CCTPAdapter } from "../../src/top-up/bridge/CCTPAdapter.sol";

/// @title VerifyTopUpFactoriesBytecode
/// @notice Deploys TopUpFactory and all chain-specific adapters locally and compares
///         bytecode against the on-chain CREATE3-deployed contracts.
///
///         Chain-specific adapters:
///         - Ethereum (1):    6 adapters (Stargate, Optimism, Hop, Liquid, OFT, CCTP)
///         - Base (8453):     4 adapters (CCTP, Liquid, OFT, Stargate)
///         - HyperEVM (999):  2 adapters (CCTP, OFT)
///         - Arbitrum (42161): 1 adapter (CCTP)
///
/// Usage:
///   ENV=mainnet forge script scripts/topups-migration/VerifyTopUpFactoriesBytecode.s.sol \
///     --rpc-url <RPC> -vvv
contract VerifyTopUpFactoriesBytecode is Script, ContractCodeChecker, GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // WETH addresses per chain (for StargateAdapter)
    address constant ETH_WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();
        address factoryProxy = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");

        console2.log("=============================================");
        console2.log("  TopUpFactory Bytecode Verification (Chain %s)", chainId);
        console2.log("=============================================\n");

        // 1. TopUpFactory impl
        bytes32 factorySalt = _getFactorySalt();
        address deployedFactoryImpl = CREATE3.predictDeterministicAddress(factorySalt, NICKS_FACTORY);
        console2.log("1. TopUpFactory impl (%s)", deployedFactoryImpl);
        verifyContractByteCodeMatch(deployedFactoryImpl, address(new TopUpFactory()));

        // 2. Simulate gnosis bundle if not yet executed
        {
            address currentImpl = address(uint160(uint256(vm.load(factoryProxy, EIP1967_IMPL_SLOT))));
            if (currentImpl != deployedFactoryImpl) {
                console2.log("2. Gnosis bundle NOT yet executed, simulating on fork...");
                string memory path = _getGnosisBundlePath(chainId);
                require(vm.exists(path), string.concat("Gnosis bundle not found at ", path));
                executeGnosisTransactionBundle(path);
                console2.log("   [OK] Gnosis bundle simulation complete\n");
            } else {
                console2.log("2. Gnosis bundle already executed on-chain\n");
            }
        }

        // 3. Factory proxy impl slot
        console2.log("3. Verifying factory proxy impl slot...");
        address actualImpl = address(uint160(uint256(vm.load(factoryProxy, EIP1967_IMPL_SLOT))));
        require(
            actualImpl == deployedFactoryImpl,
            string.concat("Factory impl mismatch - expected ", vm.toString(deployedFactoryImpl), " got ", vm.toString(actualImpl))
        );
        console2.log("  [OK] TopUpFactory -> impl", actualImpl);

        // 4. Chain-specific adapters
        if (block.chainid == 1)     _verifyEthereumAdapters();
        if (block.chainid == 8453)  _verifyBaseAdapters();
        if (block.chainid == 999)   _verifyHyperEVMAdapters();
        if (block.chainid == 42161) _verifyArbitrumAdapters();

        console2.log("\n=============================================");
        console2.log("  ALL CHECKS PASSED");
        console2.log("=============================================");
    }

    // ═══════════════════════════════════════════════════════════════
    //                     ETHEREUM (6 adapters)
    // ═══════════════════════════════════════════════════════════════

    function _verifyEthereumAdapters() internal {
        console2.log("\n4. Ethereum adapters (6)...\n");

        _verifyAdapter("StargateAdapter",
            keccak256("TopupsMigration.Prod.StargateAdapterEthereum"),
            address(new StargateAdapter(ETH_WETH)));

        _verifyAdapter("OptimismBridgeAdapter",
            keccak256("TopupsMigration.Prod.OptimismBridgeAdapterEthereum"),
            address(new OptimismBridgeAdapter()));

        _verifyAdapter("HopBridgeAdapter",
            keccak256("TopupsMigration.Prod.HopBridgeAdapterEthereum"),
            address(new HopBridgeAdapter()));

        _verifyAdapter("EtherFiLiquidBridgeAdapter",
            keccak256("TopupsMigration.Prod.EtherFiLiquidBridgeAdapterEthereum"),
            address(new EtherFiLiquidBridgeAdapter()));

        _verifyAdapter("EtherFiOFTBridgeAdapter",
            keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterEthereum"),
            address(new EtherFiOFTBridgeAdapter()));

        _verifyAdapter("CCTPAdapter",
            keccak256("TopupsMigration.Prod.CCTPAdapterEthereum"),
            address(new CCTPAdapter()));
    }

    // ═══════════════════════════════════════════════════════════════
    //                     BASE (4 adapters)
    // ═══════════════════════════════════════════════════════════════

    function _verifyBaseAdapters() internal {
        console2.log("\n4. Base adapters (4)...\n");

        _verifyAdapter("CCTPAdapter",
            keccak256("TopupsMigration.Prod.CCTPAdapterBase"),
            address(new CCTPAdapter()));

        _verifyAdapter("EtherFiLiquidBridgeAdapter",
            keccak256("TopupsMigration.Prod.EtherFiLiquidBridgeAdapterBase"),
            address(new EtherFiLiquidBridgeAdapter()));

        _verifyAdapter("EtherFiOFTBridgeAdapter",
            keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterBase"),
            address(new EtherFiOFTBridgeAdapter()));

        _verifyAdapter("StargateAdapter",
            keccak256("TopupsMigration.Prod.StargateAdapterBase"),
            address(new StargateAdapter(BASE_WETH)));
    }

    // ═══════════════════════════════════════════════════════════════
    //                     HYPEREVM (2 adapters)
    // ═══════════════════════════════════════════════════════════════

    function _verifyHyperEVMAdapters() internal {
        console2.log("\n4. HyperEVM adapters (2)...\n");

        _verifyAdapter("CCTPAdapter",
            keccak256("TopupsMigration.Prod.CCTPAdapterHyperEVM"),
            address(new CCTPAdapter()));

        _verifyAdapter("EtherFiOFTBridgeAdapter",
            keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterHyperEVM"),
            address(new EtherFiOFTBridgeAdapter()));
    }

    // ═══════════════════════════════════════════════════════════════
    //                     ARBITRUM (1 adapter)
    // ═══════════════════════════════════════════════════════════════

    function _verifyArbitrumAdapters() internal {
        console2.log("\n4. Arbitrum adapters (1)...\n");

        _verifyAdapter("CCTPAdapter",
            keccak256("TopupsMigration.Prod.CCTPAdapterArbitrum"),
            address(new CCTPAdapter()));
    }

    // ═══════════════════════════════════════════════════════════════
    //                         HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _verifyAdapter(string memory label, bytes32 salt, address localImpl) internal {
        address deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);
        console2.log("%s (%s)", label, deployed);
        verifyContractByteCodeMatch(deployed, localImpl);
    }

    function _getGnosisBundlePath(string memory chainId) internal view returns (string memory) {
        if (block.chainid == 1)     return string.concat("./output/UpgradeTopUpFactoryEthereum-", chainId, ".json");
        if (block.chainid == 8453)  return string.concat("./output/UpgradeTopUpFactoryBase-", chainId, ".json");
        if (block.chainid == 999)   return string.concat("./output/UpgradeTopUpFactoryHyperEVM-", chainId, ".json");
        if (block.chainid == 42161) return string.concat("./output/UpgradeTopUpFactoryArbitrum-", chainId, ".json");
        revert("Unsupported chain");
    }

    function _getFactorySalt() internal view returns (bytes32) {
        if (block.chainid == 1)     return keccak256("TopupsMigration.Prod.TopUpFactoryEthereumImpl");
        if (block.chainid == 8453)  return keccak256("TopupsMigration.Prod.TopUpFactoryBaseImpl");
        if (block.chainid == 999)   return keccak256("TopupsMigration.Prod.TopUpFactoryHyperEVMImpl");
        if (block.chainid == 42161) return keccak256("TopupsMigration.Prod.TopUpFactoryArbitrumImpl");
        revert("Unsupported chain");
    }
}
