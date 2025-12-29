// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { LiquidUSDLiquifierModule } from "../../src/modules/etherfi/LiquidUSDLiquifier.sol";

contract AddLiquidUsdLiquifierVerifyBytecode is ContractCodeChecker, Test {
    address liquidUSDLiquifierModuleProxy = 0xF5E78B8F9B253F376D7c1D1cAfaA793967c4ff7d;
    address liquidUSDLiquifierModuleImpl = 0xd06DE0Cd0231bC37375Ca8294A7e496bf56F4927;

    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address debtManager = 0x0078C5a459132e279056B2371fE8A8eC973A9553;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeLiquidUsdLiquifierModule_verifyBytecode() public {
        LiquidUSDLiquifierModule liquidUSDLiquifierModule = new LiquidUSDLiquifierModule(debtManager, dataProvider);

        console.log("-------------- Debt Manager ----------------");
        emit log_named_address("New deploy", address(liquidUSDLiquifierModule));
        emit log_named_address("Verifying contract", address(liquidUSDLiquifierModuleImpl));
        verifyContractByteCodeMatch(address(liquidUSDLiquifierModuleImpl), address(liquidUSDLiquifierModule));
    }
}