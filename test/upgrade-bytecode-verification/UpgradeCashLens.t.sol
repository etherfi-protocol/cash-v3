// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { CashLens } from "../../src/modules/cash/CashLens.sol";

contract UpgradeCashLensVerifyBytecode is ContractCodeChecker, Test {
    address cashLensDeployment = 0xD3F3480511FB25a3D86568B6e1eFBa09d0aDEebF;         
    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;
    
    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeCashLens_verifyBytecode() public {
        CashLens cashLens = new CashLens(cashModule, dataProvider);

        console.log("-------------- Debt Manager ----------------");
        emit log_named_address("New deploy", address(cashLens));
        emit log_named_address("Verifying contract", address(cashLensDeployment));
        verifyContractByteCodeMatch(address(cashLensDeployment), address(cashLens));
    }
}