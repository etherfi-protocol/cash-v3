// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";

contract UpgradeCashbackTypes is ContractCodeChecker, Test {
    address cashModuleCoreImpl = 0xE56a78D457f7DaB66e7Be1fBCeA9B10c32Cd25b0;
    address cashEventEmitterImpl = 0xFd311aD08e105d715BBA8BE7b0924Be3f5a6aBf7;

    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeCashback_verifyBytecode() public {
        address cashModuleCoreNewDeploy = address(new CashModuleCore(dataProvider));
        address cashEventEmitterNewDeploy = address(new CashEventEmitter(cashModule));

        console.log("-------------- Cash Module Core ----------------");
        emit log_named_address("New deploy", address(cashModuleCoreNewDeploy));
        emit log_named_address("Verifying contract", address(cashModuleCoreImpl));
        verifyContractByteCodeMatch(address(cashModuleCoreImpl), address(cashModuleCoreNewDeploy));

        console.log("-------------- Cash Event Emitter ----------------");
        emit log_named_address("New deploy", address(cashEventEmitterNewDeploy));
        emit log_named_address("Verifying contract", address(cashEventEmitterImpl));
        verifyContractByteCodeMatch(address(cashEventEmitterImpl), address(cashEventEmitterNewDeploy));
    }
}