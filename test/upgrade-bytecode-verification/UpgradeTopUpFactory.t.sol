// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// import { Test } from "forge-std/Test.sol";
// import { ContractCodeChecker } from "../scripts/utils/ContractCodeChecker.sol";
// import { TopUpFactory } from "../src/top-up/TopUpFactory.sol";

// contract UpgradeTopUpFactoryVerifyBytecode is Test, ContractCodeChecker {
//     function test_deployment_bytecode() public {
//         vm.createSelectFork("https://eth.llamarpc.com");
//         address deployedImpl = 0x1643507bCEa7FF94aCaFCc6Ac1d47F0DF3D137FE;
//         TopUpFactory topUpFactory = new TopUpFactory();
//         emit log_named_address("New deploy", address(topUpFactory));
//         verifyContractByteCodeMatch(address(deployedImpl), address(topUpFactory));
//     }
// }