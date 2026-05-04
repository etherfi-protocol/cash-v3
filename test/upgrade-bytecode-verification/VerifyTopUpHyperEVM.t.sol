// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
import { Utils } from "../utils/Utils.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { CCTPAdapter } from "../../src/top-up/bridge/CCTPAdapter.sol";
import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";

/// @title HyperEVM TopUp Bytecode Verification
/// @notice Verifies that every deployed TopUp contract on HyperEVM matches the bytecode from this repo.
///
/// Usage:
///   forge test --match-contract VerifyTopUpHyperEVMBytecode -vv
contract VerifyTopUpHyperEVMBytecode is ContractCodeChecker, Utils {
    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    string deployments;

    function setUp() public {
        vm.createSelectFork("https://rpc.hyperliquid.xyz/evm");

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

    function test_verifyBytecode_CCTPAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.CCTPAdapter");
        address local = address(new CCTPAdapter());
        _verify("CCTPAdapter", deployed, local);
    }

    function test_verifyBytecode_EtherFiOFTBridgeAdapter() public {
        address deployed = stdJson.readAddress(deployments, ".addresses.EtherFiOFTBridgeAdapter");
        address local = address(new EtherFiOFTBridgeAdapter());
        _verify("EtherFiOFTBridgeAdapter", deployed, local);
    }

    // ---- Helpers ----

    function _verify(string memory name, address deployed, address local) internal {
        console.log("------", name, "------");
        console.log("  Deployed:", deployed);
        console.log("  Local:   ", local);
        verifyContractByteCodeMatch(deployed, local);
    }
}
