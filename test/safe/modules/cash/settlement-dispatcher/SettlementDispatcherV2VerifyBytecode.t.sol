// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ContractCodeChecker } from "../../../../../scripts/utils/ContractCodeChecker.sol";
import { Test, console } from "forge-std/Test.sol";

import { BinSponsor } from "../../../../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { SettlementDispatcherV2 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";

contract SettlementDispatcherV2VerifyBytecode is ContractCodeChecker, Test {
    address constant reapDeployment      = 0xAc52B92C9B3c131B233B747cDfa15e5ec3013Fb2;
    address constant rainDeployment      = 0x6B7Db0886A7e9F95E3d39630A42456eeF8439119;
    address constant pixDeployment       = 0xa3b882edc0c9D31A311f1d59b97E21823d40a0d6;
    address constant cardOrderDeployment = 0xa93AA25303a2DF853eaAB6ffD46F08D60002B4b9;

    address constant dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io";
        vm.createSelectFork(scrollRpc);
    }

    function test_settlementDispatcherV2Reap_verifyBytecode() public {
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.Reap, dataProvider);

        console.log("-------------- SettlementDispatcherV2 Reap ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", reapDeployment);
        verifyContractByteCodeMatch(reapDeployment, address(impl));
    }

    function test_settlementDispatcherV2Rain_verifyBytecode() public {
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.Rain, dataProvider);

        console.log("-------------- SettlementDispatcherV2 Rain ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", rainDeployment);
        verifyContractByteCodeMatch(rainDeployment, address(impl));
    }

    function test_settlementDispatcherV2Pix_verifyBytecode() public {
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.PIX, dataProvider);

        console.log("-------------- SettlementDispatcherV2 PIX ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", pixDeployment);
        verifyContractByteCodeMatch(pixDeployment, address(impl));
    }

    function test_settlementDispatcherV2CardOrder_verifyBytecode() public {
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.CardOrder, dataProvider);

        console.log("-------------- SettlementDispatcherV2 CardOrder ----------------");
        emit log_named_address("New deploy", address(impl));
        emit log_named_address("Verifying contract", cardOrderDeployment);
        verifyContractByteCodeMatch(cardOrderDeployment, address(impl));
    }
}
