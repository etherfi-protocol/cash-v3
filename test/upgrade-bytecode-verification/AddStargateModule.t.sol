// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";

contract AddStargateModuleVerifyBytecode is ContractCodeChecker, Test {
    address stargateDeployment = 0x6ca9aA0Cbf0ECf0d849ecB4F9E757Fd72c1519C3;
    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

    address weETH = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    address usdcStargatePool = 0x3Fc69CC4A842838bCDC9499178740226062b14E4;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeOpenoceanSwapModule_verifyBytecode() public {
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weETH);

        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](2);

        assetConfigs[0] = StargateModule.AssetConfig({
            isOFT: false,
            pool: usdcStargatePool
        });
        assetConfigs[1] = StargateModule.AssetConfig({
            isOFT: true,
            pool: address(weETH)
        });

        StargateModule stargateModule = new StargateModule(assets, assetConfigs, dataProvider);

        console.log("-------------- Debt Manager ----------------");
        emit log_named_address("New deploy", address(stargateModule));
        emit log_named_address("Verifying contract", address(stargateDeployment));
        verifyContractByteCodeMatch(address(stargateDeployment), address(stargateModule));
    }
}