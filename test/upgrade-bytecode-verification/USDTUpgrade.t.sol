// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// import { Test, console } from "forge-std/Test.sol";
// import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

// import { SettlementDispatcher, BinSponsor } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
// import { TopUpFactory, TopUp } from "../../src/top-up/TopUpFactory.sol";
// import { BaseWithdrawERC20BridgeAdapter } from "../../src/top-up/bridge/BaseWithdrawERC20BridgeAdapter.sol";

// contract UpgradeUSDTVerifyBytecode is ContractCodeChecker, Test {
//     address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

//     address newSettlementDispatcherReapImpl = 0xD7C422a48ecE1a5f883593d6d1CcB7A5dD486a3f;
//     address newSettlementDispatcherRainImpl = 0x49859E57be078A0b9A396CBBf1B5197D13caEE92;

//     address newTopUpFactoryImplEthereum = 0xB580df5d8E6ceB72a936727DaE19F32cE4Bb303f;
//     address newTopUpImplEthereum = 0x1876eCAE880Ddf1F92E60c90e8916A3977576206;
    
//     address newTopUpFactoryImplBase = 0x4c5644c0BCD100263d28c4eB735f9143eC83847F;
//     address newTopUpImplBase = 0x8fF38032083C0E36C3CdC8c509758514Fe0a49E2;
//     address newBaseWithdrawERC20BridgeAdapterImpl = 0x83c536a18e295a5DBc8f678aA3E293Ed7884044e;

//     address wethEthereum = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
//     address wethBase = 0x4200000000000000000000000000000000000006;
    
//     function test_upgradeSettlementDispatcherScroll_verifyBytecode() public {
//         string memory scrollRpc = vm.envString("SCROLL_RPC");
//         if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
//         vm.createSelectFork(scrollRpc);

//         SettlementDispatcher settlementDispatcherReapImpl = new SettlementDispatcher(BinSponsor.Reap, dataProvider);
//         SettlementDispatcher settlementDispatcherRainImpl = new SettlementDispatcher(BinSponsor.Rain, dataProvider);

//         console.log("-------------- Settlement Dispatcher Reap ----------------");
//         emit log_named_address("New deploy", address(settlementDispatcherReapImpl));
//         emit log_named_address("Verifying contract", address(newSettlementDispatcherReapImpl));
//         verifyContractByteCodeMatch(address(newSettlementDispatcherReapImpl), address(settlementDispatcherReapImpl));

//         console.log("-------------- Settlement Dispatcher Rain ----------------");
//         emit log_named_address("New deploy", address(settlementDispatcherRainImpl));
//         emit log_named_address("Verifying contract", address(newSettlementDispatcherRainImpl));
//         verifyContractByteCodeMatch(address(newSettlementDispatcherRainImpl), address(settlementDispatcherRainImpl));
//     }

//     function test_upgradeTopUpBase_verifyBytecode() public {
//         string memory baseRpc = vm.envString("BASE_RPC");
//         if (bytes(baseRpc).length != 0) baseRpc = "https://base.llamarpc.com"; 
//         vm.createSelectFork(baseRpc);

//         TopUp topUpImpl = new TopUp(wethBase);
//         TopUpFactory topUpFactoryImpl = new TopUpFactory();
//         BaseWithdrawERC20BridgeAdapter baseWithdrawERC20BridgeAdapterImpl = new BaseWithdrawERC20BridgeAdapter();

//         console.log("-------------- TopUp ----------------");
//         emit log_named_address("New deploy", address(topUpImpl));
//         emit log_named_address("Verifying contract", address(newTopUpImplBase));
//         verifyContractByteCodeMatch(address(newTopUpImplBase), address(topUpImpl));

//         console.log("-------------- TopUp Factory ----------------");
//         emit log_named_address("New deploy", address(topUpFactoryImpl));
//         emit log_named_address("Verifying contract", address(newTopUpFactoryImplBase));
//         verifyContractByteCodeMatch(address(newTopUpFactoryImplBase), address(topUpFactoryImpl));

//         console.log("-------------- BaseWithdrawERC20BridgeAdapter ----------------");
//         emit log_named_address("New deploy", address(baseWithdrawERC20BridgeAdapterImpl));
//         emit log_named_address("Verifying contract", address(newBaseWithdrawERC20BridgeAdapterImpl));
//         verifyContractByteCodeMatch(address(newBaseWithdrawERC20BridgeAdapterImpl), address(baseWithdrawERC20BridgeAdapterImpl));
//     }

//     function test_upgradeTopUpEthereum_verifyBytecode() public {
//         string memory ethRpc = vm.envString("MAINNET_RPC");
//         if (bytes(ethRpc).length != 0) ethRpc = "https://eth.llamarpc.com"; 
//         vm.createSelectFork(ethRpc);

//         TopUp topUpImpl = new TopUp(wethEthereum);
//         TopUpFactory topUpFactoryImpl = new TopUpFactory();

//         console.log("-------------- TopUp ----------------");
//         emit log_named_address("New deploy", address(topUpImpl));
//         emit log_named_address("Verifying contract", address(newTopUpImplEthereum));
//         verifyContractByteCodeMatch(address(newTopUpImplEthereum), address(topUpImpl));

//         console.log("-------------- TopUp Factory ----------------");
//         emit log_named_address("New deploy", address(topUpFactoryImpl));
//         emit log_named_address("Verifying contract", address(newTopUpFactoryImplEthereum));
//         verifyContractByteCodeMatch(address(newTopUpFactoryImplEthereum), address(topUpFactoryImpl));
//     }
// }