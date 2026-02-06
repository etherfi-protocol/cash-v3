// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ContractCodeChecker } from "../../../../scripts/utils/ContractCodeChecker.sol";
import { Test, console } from "forge-std/Test.sol";

import { FraxModule } from "../../../../src/modules/frax/FraxModule.sol";

contract FraxVerifyBytecode is ContractCodeChecker, Test {
    address fraxModuleDeployment = 0xaE23A00A361cA7Da3f75E3312A07348AB91e34BF;
    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address fraxusd = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address custodian = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    address remoteHop = 0xF6f45CCB5E85D1400067ee66F9e168f83e86124E;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io";
        vm.createSelectFork(scrollRpc);
    }

    function test_fraxModule_verifyBytecode() public {
        FraxModule fraxModule = new FraxModule(dataProvider, fraxusd, custodian, remoteHop);

        console.log("-------------- FraxModule ----------------");
        emit log_named_address("New deploy", address(fraxModule));
        emit log_named_address("Verifying contract", address(fraxModuleDeployment));
        verifyContractByteCodeMatch(address(fraxModuleDeployment), address(fraxModule));
    }
}
