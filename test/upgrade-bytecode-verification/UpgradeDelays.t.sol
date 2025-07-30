// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";

import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { SettlementDispatcher, BinSponsor } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";

contract UpgradeDelaysVerifyBytecode is ContractCodeChecker, Test {
    address liquidModuleImpl = 0x2A0E60E26a118fF6F181B98666E6FD6BBf3e1826;
    address swapModuleImpl = 0x4dEAa5f2e1CD1A792304d1649EdfA35D565F9346;  
    address stakeModuleImpl = 0x40c8438e9cc3B7817aeb117cd0d7B829c32bfEd8;
    address stargateModuleImpl = 0xC1ab383b81fD81803a54c4d50A7b7d4A31a317b4;

    address cashModuleCoreImpl = 0x0935Eb6E978Fe95FC16adece4fdA23a8C7e92A62;
    address cashModuleSettersImpl = 0x48af1672B5814a73d4E6c641a3698e2D945260Ff;
    address cashLensImpl = 0x5D8A65f8515c32Bf8956C3e4336031BCEdDda7Db;
    address cashEventEmitterImpl = 0x0E4c9DA64e0f79234EDD4EbD18b217732a66dEc4;
    
    address dataProvider = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address cashModule = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;

    address public weth = address(0x5300000000000000000000000000000000000004);

    address public liquidEth = address(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    address public liquidEthTeller = address(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    address public liquidEthBoringQueue = 0x0D2dF071207E18Ca8638b4f04E98c53155eC2cE0;
    
    address public liquidUsd = address(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    address public liquidUsdTeller = address(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    address public liquidUsdBoringQueue = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
    
    address public liquidBtc = address(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    address public liquidBtcTeller = address(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);
    address public liquidBtcBoringQueue = 0x77A2fd42F8769d8063F2E75061FC200014E41Edf;

    address public eUsd = address(0x939778D83b46B456224A33Fb59630B11DEC56663);
    address public eUsdTeller = address(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA);

    address public ebtc = address(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642);
    address public ebtcTeller = address(0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268);

    address weETH = address(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    address syncPool = 0x750cf0fd3bc891D8D864B732BC4AD340096e5e68;

    address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    address usdcStargatePool = 0x3Fc69CC4A842838bCDC9499178740226062b14E4;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_upgradeLiquidWithdrawals_verifyBytecode() public {
        address[] memory liquidAssets = new address[](5);
        liquidAssets[0] = liquidEth;
        liquidAssets[1] = liquidBtc;
        liquidAssets[2] = liquidUsd;
        liquidAssets[3] = eUsd;
        liquidAssets[4] = ebtc;

        address[] memory liquidTellers = new address[](5);
        liquidTellers[0] = liquidEthTeller;
        liquidTellers[1] = liquidBtcTeller;
        liquidTellers[2] = liquidUsdTeller;
        liquidTellers[3] = eUsdTeller;
        liquidTellers[4] = ebtcTeller;

        address[] memory stargateAssets = new address[](2);
        stargateAssets[0] = address(usdc);
        stargateAssets[1] = address(weETH);

        StargateModule.AssetConfig[] memory stargateAssetConfigs = new StargateModule.AssetConfig[](2);

        stargateAssetConfigs[0] = StargateModule.AssetConfig({
            isOFT: false,
            pool: usdcStargatePool
        });
        stargateAssetConfigs[1] = StargateModule.AssetConfig({
            isOFT: true,
            pool: address(weETH)
        });

        address newCashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        address newCashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        address newCashLensImpl = address(new CashLens(cashModule, dataProvider));
        address newCashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        address newStakeModule = address(new EtherFiStakeModule(dataProvider, syncPool, weth, weETH));
        address newLiquidModule = address(new EtherFiLiquidModule(liquidAssets, liquidTellers, dataProvider, weth));
        address newOpenOceanModule = address(new OpenOceanSwapModule(openOceanSwapRouter, dataProvider));
        address newStargateModule = address(new StargateModule(stargateAssets, stargateAssetConfigs, dataProvider));

        console.log("-------------- Cash Module Core ----------------");
        emit log_named_address("New deploy", address(newCashModuleCoreImpl));
        emit log_named_address("Verifying contract", address(cashModuleCoreImpl));
        verifyContractByteCodeMatch(address(cashModuleCoreImpl), address(newCashModuleCoreImpl));

        console.log("-------------- Cash Module Setters ----------------");
        emit log_named_address("New deploy", address(newCashModuleSettersImpl));
        emit log_named_address("Verifying contract", address(cashModuleSettersImpl));
        verifyContractByteCodeMatch(address(cashModuleSettersImpl), address(newCashModuleSettersImpl));

        console.log("-------------- Cash Lens ----------------");
        emit log_named_address("New deploy", address(newCashLensImpl));
        emit log_named_address("Verifying contract", address(cashLensImpl));
        verifyContractByteCodeMatch(address(cashLensImpl), address(newCashLensImpl));

        console.log("-------------- Cash Event Emitter ----------------");
        emit log_named_address("New deploy", address(newCashEventEmitterImpl));
        emit log_named_address("Verifying contract", address(cashEventEmitterImpl));
        verifyContractByteCodeMatch(address(cashEventEmitterImpl), address(newCashEventEmitterImpl));
     
    
        console.log("-------------- Liquid Module ----------------");
        emit log_named_address("New deploy", address(newLiquidModule));
        emit log_named_address("Verifying contract", address(liquidModuleImpl));
        verifyContractByteCodeMatch(address(liquidModuleImpl), address(newLiquidModule));
     
        console.log("-------------- OpenOcean Module ----------------");
        emit log_named_address("New deploy", address(newOpenOceanModule));
        emit log_named_address("Verifying contract", address(swapModuleImpl));
        verifyContractByteCodeMatch(address(swapModuleImpl), address(newOpenOceanModule));
     
        console.log("-------------- Stargate Module ----------------");
        emit log_named_address("New deploy", address(newStargateModule));
        emit log_named_address("Verifying contract", address(stargateModuleImpl));
        verifyContractByteCodeMatch(address(stargateModuleImpl), address(newStargateModule));
     
        console.log("-------------- Stake Module ----------------");
        emit log_named_address("New deploy", address(newStakeModule));
        emit log_named_address("Verifying contract", address(stakeModuleImpl));
        verifyContractByteCodeMatch(address(stakeModuleImpl), address(newStakeModule));
    }
}