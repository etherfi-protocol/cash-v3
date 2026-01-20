// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ContractCodeChecker } from "../../../../scripts/utils/ContractCodeChecker.sol";
import { Test, console } from "forge-std/Test.sol";

import { MidasModule } from "../../../../src/modules/midas/MidasModule.sol";

contract MidasVerifyBytecode is ContractCodeChecker, Test {
    address midasModuleDeployment = 0xEE3Fb6914105BA01196ab26191C3BB7448016467;
    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address midasToken = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address depositVault = 0xcA1C871f8ae2571Cb126A46861fc06cB9E645152;
    address redemptionVault = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io";
        vm.createSelectFork(scrollRpc);
    }

    function test_midasModule_verifyBytecode() public {
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = midasToken;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = depositVault;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = redemptionVault;

        MidasModule midasModule = new MidasModule(dataProvider, midasTokens, depositVaults, redemptionVaults);

        console.log("-------------- MidasModule ----------------");
        emit log_named_address("New deploy", address(midasModule));
        emit log_named_address("Verifying contract", address(midasModuleDeployment));
        verifyContractByteCodeMatch(address(midasModuleDeployment), address(midasModule));
    }
}
