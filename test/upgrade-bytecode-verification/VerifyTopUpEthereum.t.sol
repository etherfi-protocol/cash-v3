// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
import { Utils } from "../utils/Utils.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StargateAdapter } from "../../src/top-up/bridge/StargateAdapter.sol";
import { OptimismBridgeAdapter } from "../../src/top-up/bridge/OptimismBridgeAdapter.sol";
import { HopBridgeAdapter } from "../../src/top-up/bridge/HopBridgeAdapter.sol";
import { EtherFiLiquidBridgeAdapter } from "../../src/top-up/bridge/EtherFiLiquidBridgeAdapter.sol";
import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import { CCTPAdapter } from "../../src/top-up/bridge/CCTPAdapter.sol";

/// @title Ethereum TopUp Bytecode Verification
/// @notice Verifies that every deployed TopUp contract on Ethereum mainnet matches the bytecode from this repo.
///
/// Usage:
///   forge test --match-contract VerifyTopUpEthereumBytecode -vv
contract VerifyTopUpEthereumBytecode is ContractCodeChecker, Utils {
    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    string deployments;

    function setUp() public {
        string memory rpc = _tryEnv("MAINNET_RPC", "https://eth.llamarpc.com");
        vm.createSelectFork(rpc);

        deployments = readDeploymentFile();
    }

    // ---- TopUpFactory (proxy → impl) ----

    function test_verifyBytecode_TopUpFactory() public {
        address proxy = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        address deployed = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        address local = address(new TopUpFactory());
        _verify("TopUpFactory", deployed, local);
    }

    // ---- Bridge Adapters ----

    function test_verifyBytecode_StargateAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.StargateAdapter");
        address local = address(new StargateAdapter(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
        _verify("StargateAdapter", deployed, local);
    }

    function test_verifyBytecode_OptimismBridgeAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.OptimismBridgeAdapter");
        address local = address(new OptimismBridgeAdapter());
        _verify("OptimismBridgeAdapter", deployed, local);
    }

    function test_verifyBytecode_HopBridgeAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.HopBridgeAdapter");
        address local = address(new HopBridgeAdapter());
        _verify("HopBridgeAdapter", deployed, local);
    }

    function test_verifyBytecode_EtherFiLiquidBridgeAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.EtherFiLiquidBridgeAdapter");
        address local = address(new EtherFiLiquidBridgeAdapter());
        _verify("EtherFiLiquidBridgeAdapter", deployed, local);
    }

    function test_verifyBytecode_EtherFiOFTBridgeAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.EtherFiOFTBridgeAdapter");
        address local = address(new EtherFiOFTBridgeAdapter());
        _verify("EtherFiOFTBridgeAdapter", deployed, local);
    }

    function test_verifyBytecode_CCTPAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.CCTPAdapter");
        address local = address(new CCTPAdapter());
        _verify("CCTPAdapter", deployed, local);
    }

    // ---- Helpers ----

    function _verify(string memory name, address deployed, address local) internal {
        console.log("------", name, "------");
        console.log("  Deployed:", deployed);
        console.log("  Local:   ", local);
        verifyContractByteCodeMatch(deployed, local);
    }

    function _tryEnv(string memory key, string memory fallback_) internal view returns (string memory) {
        try vm.envString(key) returns (string memory val) {
            return bytes(val).length > 0 ? val : fallback_;
        } catch {
            return fallback_;
        }
    }
}
