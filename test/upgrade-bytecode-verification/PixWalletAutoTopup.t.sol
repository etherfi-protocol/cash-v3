// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { PixWalletAutoTopup } from "../../src/pix-auto-topup/PixWalletAutoTopup.sol";

// contract PixWalletAutoTopupVerifyBytecode is ContractCodeChecker, Test {
//     address pixWalletAutoTopupDeploymentImpl = 0xbF841142EBd5241968cDBB9958591ac93d93AB9b;

//     function setUp() public {
//         string memory rpc = vm.envString("MAINNET_RPC");
//         if (bytes(rpc).length == 0) rpc = "https://eth.llamarpc.com"; 
//         vm.createSelectFork(rpc);
//     }

//     function test_pixWalletAutoTopup_verifyBytecode() public {
//         address pixWalletAutoTopupImpl = address(new PixWalletAutoTopup());
//         emit log_named_address("New deploy", address(pixWalletAutoTopupImpl));
//         emit log_named_address("Verifying contract", address(pixWalletAutoTopupDeploymentImpl));
//         verifyContractByteCodeMatch(address(pixWalletAutoTopupDeploymentImpl), address(pixWalletAutoTopupImpl));
//     }
// }
