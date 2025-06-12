// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// import { Test, console } from "forge-std/Test.sol";
// import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

// import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
// import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
// import { SettlementDispatcher, BinSponsor } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
// import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
// import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";

// contract UpgradeLiquidWithdrawalsVerifyBytecode is ContractCodeChecker, Test {
//     address settlementDispatcherRainImpl = 0x3E662fa9d7e0Af805b8ab3083ee6f88e55536B7D;
//     address settlementDispatcherReapImpl = 0x12A5b7C4F5978D67809F94D6a5D8D559102Bd975;
//     address dataProviderImpl = 0x32eC194A83637263b8b22806d07d84cC3DA027EA;
//     address liquidModuleImpl = 0x62f623161fdB6564925c3F9B783cbDfeF4CE8AEc;
//     address swapModuleImpl = 0x57d23DEa576c88AA5a3F919b1a38f44E1D4b0512;  
    
//     address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
//     address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;

//     address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

//     address public liquidEth = address(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
//     address public liquidEthTeller = address(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    
//     address public liquidUsd = address(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
//     address public liquidUsdTeller = address(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
//     address public liquidBtc = address(0x5f46d540b6eD704C3c8789105F30E075AA900726);
//     address public liquidBtcTeller = address(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);

//     address public eUsd = address(0x939778D83b46B456224A33Fb59630B11DEC56663);
//     address public eUsdTeller = address(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA);

//     address public ebtc = address(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642);
//     address public ebtcTeller = address(0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268);

//     address public weth = address(0x5300000000000000000000000000000000000004);

//     function setUp() public {
//         string memory scrollRpc = vm.envString("SCROLL_RPC");
//         if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
//         vm.createSelectFork(scrollRpc);
//     }

//     function test_upgradeLiquidWithdrawals_verifyBytecode() public {
//         EtherFiDataProvider newDataProvider = new EtherFiDataProvider();
//         SettlementDispatcher settlementDispatcherRain = new SettlementDispatcher(BinSponsor.Rain, dataProvider);
//         SettlementDispatcher settlementDispatcherReap = new SettlementDispatcher(BinSponsor.Reap, dataProvider);
//         OpenOceanSwapModule swapModule = new OpenOceanSwapModule(openOceanSwapRouter, dataProvider);
        
//         address[] memory assets = new address[](5);
//         assets[0] = liquidEth;
//         assets[1] = liquidBtc;
//         assets[2] = liquidUsd;
//         assets[3] = eUsd;
//         assets[4] = ebtc;

//         address[] memory tellers = new address[](5);
//         tellers[0] = liquidEthTeller;
//         tellers[1] = liquidBtcTeller;
//         tellers[2] = liquidUsdTeller;
//         tellers[3] = eUsdTeller;
//         tellers[4] = ebtcTeller;

//         EtherFiLiquidModule liquidModule = new EtherFiLiquidModule(assets, tellers, dataProvider, weth);
        
//         console.log("-------------- Data Provider ----------------");
//         emit log_named_address("New deploy", address(newDataProvider));
//         emit log_named_address("Verifying contract", address(dataProviderImpl));
//         verifyContractByteCodeMatch(address(dataProviderImpl), address(newDataProvider));
     
//         console.log("-------------- Settlement Dispatcher Rain ----------------");
//         emit log_named_address("New deploy", address(settlementDispatcherRain));
//         emit log_named_address("Verifying contract", address(settlementDispatcherRainImpl));
//         verifyContractByteCodeMatch(address(settlementDispatcherRainImpl), address(settlementDispatcherRain));
     
//         console.log("-------------- Settlement Dispatcher Reap ----------------");
//         emit log_named_address("New deploy", address(settlementDispatcherReap));
//         emit log_named_address("Verifying contract", address(settlementDispatcherReapImpl));
//         verifyContractByteCodeMatch(address(settlementDispatcherReapImpl), address(settlementDispatcherReap));
     
//         console.log("-------------- Liquid Module ----------------");
//         emit log_named_address("New deploy", address(liquidModule));
//         emit log_named_address("Verifying contract", address(liquidModuleImpl));
//         verifyContractByteCodeMatch(address(liquidModuleImpl), address(liquidModule));
     
//         console.log("-------------- OpenOcean Module ----------------");
//         emit log_named_address("New deploy", address(swapModule));
//         emit log_named_address("Verifying contract", address(swapModuleImpl));
//         verifyContractByteCodeMatch(address(swapModuleImpl), address(swapModule));
//     }
// }