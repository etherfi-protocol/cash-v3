// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
// import { Test, console } from "forge-std/Test.sol";

// import { BinSponsor } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
// import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";

// contract SettlementDispatcherV2VerifyBytecode is ContractCodeChecker, Test {
//     address constant reapDeployment      = 0xB5505C09C327836D34894ebe249538F8163b8Ac8;
//     address constant rainDeployment      = 0x5bB885141dfF888504f79008E85Fc33E04fF4620;
//     address constant pixDeployment       = 0x2bc6a8D94373Ba7813d7D7Bb84E4E6ff2a663070;
//     address constant cardOrderDeployment = 0x2aC3f498496E34E3D8B22899f135236d07111BD5;

//     address constant dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

//     function setUp() public {
//         string memory scrollRpc = vm.envString("SCROLL_RPC");
//         if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io";
//         vm.createSelectFork(scrollRpc);
//     }

//     function test_settlementDispatcherV2Reap_verifyBytecode() public {
//         SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.Reap, dataProvider);

//         console.log("-------------- SettlementDispatcherV2 Reap ----------------");
//         emit log_named_address("New deploy", address(impl));
//         emit log_named_address("Verifying contract", reapDeployment);
//         verifyContractByteCodeMatch(reapDeployment, address(impl));
//     }

//     function test_settlementDispatcherV2Rain_verifyBytecode() public {
//         SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.Rain, dataProvider);

//         console.log("-------------- SettlementDispatcherV2 Rain ----------------");
//         emit log_named_address("New deploy", address(impl));
//         emit log_named_address("Verifying contract", rainDeployment);
//         verifyContractByteCodeMatch(rainDeployment, address(impl));
//     }

//     function test_settlementDispatcherV2Pix_verifyBytecode() public {
//         SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.PIX, dataProvider);

//         console.log("-------------- SettlementDispatcherV2 PIX ----------------");
//         emit log_named_address("New deploy", address(impl));
//         emit log_named_address("Verifying contract", pixDeployment);
//         verifyContractByteCodeMatch(pixDeployment, address(impl));
//     }

//     function test_settlementDispatcherV2CardOrder_verifyBytecode() public {
//         SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.CardOrder, dataProvider);

//         console.log("-------------- SettlementDispatcherV2 CardOrder ----------------");
//         emit log_named_address("New deploy", address(impl));
//         emit log_named_address("Verifying contract", cardOrderDeployment);
//         verifyContractByteCodeMatch(cardOrderDeployment, address(impl));
//     }
// }
