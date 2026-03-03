// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";

// contract EthTopUpUpgrade is ContractCodeChecker, Test {
//     address wethEthereum = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
//     address wethBase = 0x4200000000000000000000000000000000000006;
//     address wethArbitrum = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

//     function test_EthTopUpUpgrade_verifyBytecode_Ethereum() public {
//         string memory rpc = vm.envString("MAINNET_RPC");
//         if (bytes(rpc).length == 0) rpc = "https://eth.llamarpc.com"; 
//         vm.createSelectFork(rpc);

//         address topUpFactoryImpl = 0xEE3Fb6914105BA01196ab26191C3BB7448016467;
//         address topUpImpl = 0x5BdD4b0D644c0A573E0eb526aB7D7d332AAaa50e;

//         address topUpFactoryImplNew = payable(address(new TopUpFactory()));
//         address topUpImplNew = payable(address(new TopUp(getWeth(1))));

//         console.log("-------------- TopUp Factory ----------------");
//         emit log_named_address("New deploy", address(topUpFactoryImplNew));
//         emit log_named_address("Verifying contract", address(topUpFactoryImpl));
//         verifyContractByteCodeMatch(address(topUpFactoryImpl), address(topUpFactoryImplNew));

//         console.log("-------------- TopUp ----------------");
//         emit log_named_address("New deploy", address(topUpImplNew));
//         emit log_named_address("Verifying contract", address(topUpImpl));
//         verifyContractByteCodeMatch(address(topUpImpl), address(topUpImplNew));
//     }

//     function test_EthTopUpUpgrade_verifyBytecode_Base() public {
//         string memory rpc = vm.envString("BASE_RPC");
//         if (bytes(rpc).length == 0) rpc = "https://base-mainnet.public.blastapi.io"; 
//         vm.createSelectFork(rpc);

//         address topUpFactoryImpl = 0x19b7D5e748201Eb0A7B1A69130887d4b705d0A07;
//         address topUpImpl = 0x4515221124EBC0047900C03Fd3B8c98875bED3e3;

//         address topUpFactoryImplNew = payable(address(new TopUpFactory()));
//         address topUpImplNew = payable(address(new TopUp(getWeth(8453))));

//         console.log("-------------- TopUp Factory ----------------");
//         emit log_named_address("New deploy", address(topUpFactoryImplNew));
//         emit log_named_address("Verifying contract", address(topUpFactoryImpl));
//         verifyContractByteCodeMatch(address(topUpFactoryImpl), address(topUpFactoryImplNew));

//         console.log("-------------- TopUp ----------------");
//         emit log_named_address("New deploy", address(topUpImplNew));
//         emit log_named_address("Verifying contract", address(topUpImpl));
//         verifyContractByteCodeMatch(address(topUpImpl), address(topUpImplNew));
//     }

//     function test_EthTopUpUpgrade_verifyBytecode_Arbitrum() public {
//         string memory rpc = vm.envString("ARBITRUM_RPC");
//         if (bytes(rpc).length == 0) rpc = "https://arbitrum-one-rpc.publicnode.com"; 
//         vm.createSelectFork(rpc);

//         address topUpFactoryImpl = 0xde8A2C33655ACA88f258988ED74D1511876343D1;
//         address topUpImpl = 0x70d7E0C93D8443325550Ba3F71576F5f346b8aA9;

//         address topUpFactoryImplNew = payable(address(new TopUpFactory()));
//         address topUpImplNew = payable(address(new TopUp(getWeth(42161))));

//         console.log("-------------- TopUp Factory ----------------");
//         emit log_named_address("New deploy", address(topUpFactoryImplNew));
//         emit log_named_address("Verifying contract", address(topUpFactoryImpl));
//         verifyContractByteCodeMatch(address(topUpFactoryImpl), address(topUpFactoryImplNew));

//         console.log("-------------- TopUp ----------------");
//         emit log_named_address("New deploy", address(topUpImplNew));
//         emit log_named_address("Verifying contract", address(topUpImpl));
//         verifyContractByteCodeMatch(address(topUpImpl), address(topUpImplNew));
//     }

//     function getWeth(uint256 chainID) internal view returns (address) {
//         if (chainID == 1) return wethEthereum;
//         else if (chainID == 8453) return wethBase;
//         else if (chainID == 42161) return wethArbitrum;
//         else revert ("bad chain ID");
//     }
// }
