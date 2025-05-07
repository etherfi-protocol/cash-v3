// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";

contract UpgradeOpenOceanModuleVerifyBytecode is ContractCodeChecker, Test {
    address openOceanDeployment = 0x115340754572c32222D358449D7588eA809B1099;         
    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    
    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeOpenoceanSwapModule_verifyBytecode() public {
        OpenOceanSwapModule swapModule = new OpenOceanSwapModule(openOceanSwapRouter, dataProvider);

        console.log("-------------- Debt Manager ----------------");
        emit log_named_address("New deploy", address(swapModule));
        emit log_named_address("Verifying contract", address(openOceanDeployment));
        verifyContractByteCodeMatch(address(openOceanDeployment), address(swapModule));
    }
}