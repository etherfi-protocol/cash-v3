// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { CCTPAdapter } from "../../src/top-up/bridge/CCTPAdapter.sol";

contract CCTPAdapterArbitrumVerifyBytecode is ContractCodeChecker, Test {
    address cctpAdapterDeployment = 0x53A327cce6eDD6A887169Fa658271ff3588a383e;

    function setUp() public {
        string memory arbitrumRpc = vm.envString("ARBITRUM_RPC");
        if (bytes(arbitrumRpc).length == 0) arbitrumRpc = "https://arb1.arbitrum.io/rpc"; 
        vm.createSelectFork(arbitrumRpc);
    }

    function test_cctpAdapterArbitrum_verifyBytecode() public {
        CCTPAdapter cctpAdapter = new CCTPAdapter();

        console.log("-------------- CCTPAdapter ----------------");
        emit log_named_address("New deploy", address(cctpAdapter));
        emit log_named_address("Verifying contract", address(cctpAdapterDeployment));
        verifyContractByteCodeMatch(address(cctpAdapterDeployment), address(cctpAdapter));
    }
}

