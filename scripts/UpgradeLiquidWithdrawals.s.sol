// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { SettlementDispatcher, BinSponsor } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { Utils } from "./utils/Utils.sol";


contract UpgradeLiquidWithdrawals is Utils {
    address public weth = address(0x5300000000000000000000000000000000000004);

    address public liquidEth = address(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    address public liquidEthTeller = address(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    
    address public liquidUsd = address(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    address public liquidUsdTeller = address(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
    address public liquidBtc = address(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    address public liquidBtcTeller = address(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);

    address public eUsd = address(0x939778D83b46B456224A33Fb59630B11DEC56663);
    address public eUsdTeller = address(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA);

    address public ebtc = address(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642);
    address public ebtcTeller = address(0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268);
    
    address public liquidUsdBoringQueue = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
    address public liquidEthBoringQueue = 0x0D2dF071207E18Ca8638b4f04E98c53155eC2cE0;
    address public liquidBtcBoringQueue = 0x77A2fd42F8769d8063F2E75061FC200014E41Edf;

    address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    address refundWallet = 0x2e0BE8D3D9f1833fbACf9A5e9f2d470817Ff0c00;

    OpenOceanSwapModule openOceanSwapModule;
    EtherFiLiquidModule liquidModule;
    EtherFiDataProvider dataProviderImpl;
    SettlementDispatcher settlementDispatcherReapImpl;
    SettlementDispatcher settlementDispatcherRainImpl;

    event LiquidModuleDeployed(address liquidModule);
    event SwapModuleDeployed(address swapModule);

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );  

        address payable settlementDispatcherReap = payable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherReap"))
        ));  

        address payable settlementDispatcherRain = payable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherRain"))
        ));  

        _deploySwapModule(dataProvider);
        _deployLiquidModule(dataProvider);
        _whitelistModules(dataProvider);
        _upgradeDataProvider(dataProvider);
        _upgradeSettlementDispatcher(dataProvider, settlementDispatcherReap, settlementDispatcherRain);

        assert(EtherFiDataProvider(dataProvider).getRefundWallet() == refundWallet);
        assert(EtherFiDataProvider(dataProvider).isDefaultModule(address(liquidModule)));
        assert(EtherFiDataProvider(dataProvider).isDefaultModule(address(openOceanSwapModule)));
        
        vm.stopBroadcast();
    }

    function _upgradeSettlementDispatcher(address dataProvider, address payable dispatcherReap, address payable dispatcherRain) internal {
        settlementDispatcherReapImpl = new SettlementDispatcher(BinSponsor.Reap, dataProvider);
        settlementDispatcherRainImpl = new SettlementDispatcher(BinSponsor.Rain, dataProvider);

        UUPSUpgradeable(dispatcherReap).upgradeToAndCall(address(settlementDispatcherReapImpl), "");
        UUPSUpgradeable(dispatcherRain).upgradeToAndCall(address(settlementDispatcherRainImpl), "");

        SettlementDispatcher(dispatcherReap).setLiquidAssetWithdrawQueue(address(liquidUsd), liquidUsdBoringQueue);
        SettlementDispatcher(dispatcherReap).setLiquidAssetWithdrawQueue(address(liquidEth), liquidEthBoringQueue);
        SettlementDispatcher(dispatcherReap).setLiquidAssetWithdrawQueue(address(liquidBtc), liquidBtcBoringQueue);

        SettlementDispatcher(dispatcherRain).setLiquidAssetWithdrawQueue(address(liquidUsd), liquidUsdBoringQueue);
        SettlementDispatcher(dispatcherRain).setLiquidAssetWithdrawQueue(address(liquidEth), liquidEthBoringQueue);
        SettlementDispatcher(dispatcherRain).setLiquidAssetWithdrawQueue(address(liquidBtc), liquidBtcBoringQueue);
    }

    function _upgradeDataProvider(address dataProvider) internal {
        dataProviderImpl = new EtherFiDataProvider();
        UUPSUpgradeable(dataProvider).upgradeToAndCall(address(dataProviderImpl), "");
        EtherFiDataProvider(dataProvider).setRefundWallet(refundWallet);
    }

    function _deploySwapModule(address dataProvider) internal {
        openOceanSwapModule = new OpenOceanSwapModule(openOceanSwapRouter, dataProvider);
        emit SwapModuleDeployed(address(openOceanSwapModule));
    }

    function _deployLiquidModule(address dataProvider) internal {
        address[] memory assets = new address[](5);
        assets[0] = liquidEth;
        assets[1] = liquidBtc;
        assets[2] = liquidUsd;
        assets[3] = eUsd;
        assets[4] = ebtc;

        address[] memory tellers = new address[](5);
        tellers[0] = liquidEthTeller;
        tellers[1] = liquidBtcTeller;
        tellers[2] = liquidUsdTeller;
        tellers[3] = eUsdTeller;
        tellers[4] = ebtcTeller;

        liquidModule = new EtherFiLiquidModule(assets, tellers, dataProvider, weth);

        emit LiquidModuleDeployed(address(liquidModule));

        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), liquidUsdBoringQueue);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidBtc), liquidBtcBoringQueue);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidEth), liquidEthBoringQueue);
    }

    function _whitelistModules(address dataProvider) internal {
        address[] memory modules = new address[](2);
        modules[0] = address(liquidModule);
        modules[1] = address(openOceanSwapModule);
        

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, shouldWhitelist);
    }
}