// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { WormholeModule } from "../../src/modules/wormhole/WormholeModule.sol";

// contract AddWormholeModuleVerifyBytecode is ContractCodeChecker, Test {
//     address wormholeDeployment = 0x96bae80F91DA04a59CeF9dCE3bB1081De041C1d5;
//     address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

//     address ethfi = 0x056A5FA5da84ceb7f93d36e545C5905607D8bD81;
//     address ethfiNttManager = 0x552c09b224ec9146442767C0092C2928b61f62A1;
//     uint8 dustDecimals = 10;
    
//     function setUp() public {
//         string memory scrollRpc = vm.envString("SCROLL_RPC");
//         if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
//         vm.createSelectFork(scrollRpc);
//     }

//     function test_upgradeWormholeModule_verifyBytecode() public {
//         address[] memory assets = new address[](1);
//         assets[0] = address(ethfi);

//         WormholeModule.AssetConfig[] memory assetConfigs = new WormholeModule.AssetConfig[](1);

//         assetConfigs[0] = WormholeModule.AssetConfig({
//             nttManager: ethfiNttManager,
//             dustDecimals: dustDecimals
//         });

//         WormholeModule wormholeModule = new WormholeModule(assets, assetConfigs, dataProvider);

//         console.log("-------------- Wormhole Module ----------------");
//         emit log_named_address("New deploy", address(wormholeModule));
//         emit log_named_address("Verifying contract", address(wormholeDeployment));
//         verifyContractByteCodeMatch(address(wormholeDeployment), address(wormholeModule));
//     }
// }
