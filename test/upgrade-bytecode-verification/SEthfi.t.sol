// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";

contract SEthfiVerifyBytecode is ContractCodeChecker, Test {
    address etherFiLiquidModuleWithReferrerDeployment = 0x5BdD4b0D644c0A573E0eb526aB7D7d332AAaa50e;         
    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address weth = 0x5300000000000000000000000000000000000004;
    address sETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address sETHFITeller = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;
    address sETHFIBoringQueue = 0xF03352da1536F31172A7F7cB092D4717DeDDd3CB;
    
    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeCashLens_verifyBytecode() public {
        address[] memory assets = new address[](1);
        assets[0] = address(sETHFI);
        
        address[] memory tellers = new address[](1);
        tellers[0] = address(sETHFITeller);
        
        EtherFiLiquidModuleWithReferrer etherFiLiquidModuleWithReferrer = new EtherFiLiquidModuleWithReferrer(assets, tellers, dataProvider, weth);

        console.log("-------------- EtherFiLiquidModuleWithReferrer ----------------");
        emit log_named_address("New deploy", address(etherFiLiquidModuleWithReferrer));
        emit log_named_address("Verifying contract", address(etherFiLiquidModuleWithReferrerDeployment));
        verifyContractByteCodeMatch(address(etherFiLiquidModuleWithReferrerDeployment), address(etherFiLiquidModuleWithReferrer));
    }
}