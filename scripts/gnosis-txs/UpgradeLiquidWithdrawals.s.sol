// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { SettlementDispatcher, BinSponsor } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { Utils } from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";


contract UpgradeLiquidWithdrawals is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
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

    address refundWallet = 0xF6B3422e3CC70fa9fce4fAb9A706ED2497c7bb9e;

    OpenOceanSwapModule openOceanSwapModule;
    EtherFiLiquidModule liquidModule;
    EtherFiDataProvider dataProviderImpl;
    SettlementDispatcher settlementDispatcherReapImpl;
    SettlementDispatcher settlementDispatcherRainImpl;

    address payable dispatcherReap;
    address payable dispatcherRain;
    address dataProvider;
    string txs; 

    function run() public {
        vm.startBroadcast();

        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();
        
        dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );  

        dispatcherReap = payable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherReap"))
        ));  

        dispatcherRain = payable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherRain"))
        ));  

        txs = _getGnosisHeader(chainId, addressToHex(safe));

        _deploySwapModule();
        _deployLiquidModule();
        _whitelistModules();
        _upgradeDataProvider();
        _upgradeSettlementDispatcher();
        _setWithdrawQueue();

        vm.stopBroadcast();

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeLiquidWithdrawals.json";
        vm.writeFile(path, txs);
        
        executeGnosisTransactionBundle(path);

        assert(EtherFiDataProvider(dataProvider).getRefundWallet() == refundWallet);
        assert(EtherFiDataProvider(dataProvider).isDefaultModule(address(liquidModule)));
        assert(EtherFiDataProvider(dataProvider).isDefaultModule(address(openOceanSwapModule)));

        assert(SettlementDispatcher(dispatcherReap).getRefundWallet() == refundWallet);
        assert(SettlementDispatcher(dispatcherReap).getLiquidAssetWithdrawQueue(liquidUsd) == liquidUsdBoringQueue);
        assert(SettlementDispatcher(dispatcherReap).getLiquidAssetWithdrawQueue(liquidBtc) == liquidBtcBoringQueue);
        assert(SettlementDispatcher(dispatcherReap).getLiquidAssetWithdrawQueue(liquidEth) == liquidEthBoringQueue);

        assert(SettlementDispatcher(dispatcherRain).getRefundWallet() == refundWallet);
        assert(SettlementDispatcher(dispatcherRain).getLiquidAssetWithdrawQueue(liquidUsd) == liquidUsdBoringQueue);
        assert(SettlementDispatcher(dispatcherRain).getLiquidAssetWithdrawQueue(liquidBtc) == liquidBtcBoringQueue);
        assert(SettlementDispatcher(dispatcherRain).getLiquidAssetWithdrawQueue(liquidEth) == liquidEthBoringQueue);

        assert(liquidModule.getLiquidAssetWithdrawQueue(liquidUsd) == liquidUsdBoringQueue);
        assert(liquidModule.getLiquidAssetWithdrawQueue(liquidBtc) == liquidBtcBoringQueue);
        assert(liquidModule.getLiquidAssetWithdrawQueue(liquidEth) == liquidEthBoringQueue);
    }

    function _upgradeSettlementDispatcher() internal returns (string memory) {
        settlementDispatcherReapImpl = new SettlementDispatcher(BinSponsor.Reap, dataProvider);
        settlementDispatcherRainImpl = new SettlementDispatcher(BinSponsor.Rain, dataProvider);

        string memory upgradeReap = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(settlementDispatcherReapImpl), ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dispatcherReap), upgradeReap, "0", false)));

        string memory upgradeRain = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(settlementDispatcherRainImpl), ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dispatcherRain), upgradeRain, "0", false)));

        return txs;
    }

    function _upgradeDataProvider() internal returns (string memory) {
        dataProviderImpl = new EtherFiDataProvider();

        string memory upgradeDataProvider = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(dataProviderImpl), ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), upgradeDataProvider, "0", false)));

        string memory setRefundWallet = iToHex(abi.encodeWithSelector(EtherFiDataProvider.setRefundWallet.selector, address(refundWallet)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), setRefundWallet, "0", false)));

        return txs;
    }

    function _deploySwapModule() internal {
        openOceanSwapModule = new OpenOceanSwapModule(openOceanSwapRouter, dataProvider);
    }

    function _deployLiquidModule() internal {
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
    }

    function _whitelistModules() internal returns (string memory) {
        address[] memory modules = new address[](2);
        modules[0] = address(liquidModule);
        modules[1] = address(openOceanSwapModule);

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        string memory configureDefaultModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureDefaultModules, "0", false)));

        return txs;
    }

    function _setWithdrawQueue() internal returns (string memory) {
        string memory setLiquidUsdQueueSettlementReap = iToHex(abi.encodeWithSelector(SettlementDispatcher.setLiquidAssetWithdrawQueue.selector, address(liquidUsd), liquidUsdBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dispatcherReap)), setLiquidUsdQueueSettlementReap, "0", false)));
        
        string memory setLiquidEthQueueSettlementReap = iToHex(abi.encodeWithSelector(SettlementDispatcher.setLiquidAssetWithdrawQueue.selector, address(liquidEth), liquidEthBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dispatcherReap)), setLiquidEthQueueSettlementReap, "0", false)));
        
        string memory setLiquidBtcQueueSettlementReap = iToHex(abi.encodeWithSelector(SettlementDispatcher.setLiquidAssetWithdrawQueue.selector, address(liquidBtc), liquidBtcBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dispatcherReap)), setLiquidBtcQueueSettlementReap, "0", false)));
        
        string memory setLiquidUsdQueueSettlementRain = iToHex(abi.encodeWithSelector(SettlementDispatcher.setLiquidAssetWithdrawQueue.selector, address(liquidUsd), liquidUsdBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dispatcherRain)), setLiquidUsdQueueSettlementRain, "0", false)));
        
        string memory setLiquidEthQueueSettlementRain = iToHex(abi.encodeWithSelector(SettlementDispatcher.setLiquidAssetWithdrawQueue.selector, address(liquidEth), liquidEthBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dispatcherRain)), setLiquidEthQueueSettlementRain, "0", false)));
        
        string memory setLiquidBtcQueueSettlementRain = iToHex(abi.encodeWithSelector(SettlementDispatcher.setLiquidAssetWithdrawQueue.selector, address(liquidBtc), liquidBtcBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dispatcherRain)), setLiquidBtcQueueSettlementRain, "0", false)));

        string memory setLiquidUsdQueueLiquidModule = iToHex(abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, address(liquidUsd), liquidUsdBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(liquidModule)), setLiquidUsdQueueLiquidModule, "0", false)));
        
        string memory setLiquidEthQueueLiquidModule = iToHex(abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, address(liquidEth), liquidEthBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(liquidModule)), setLiquidEthQueueLiquidModule, "0", false)));
        
        string memory setLiquidBtcQueueLiquidModule = iToHex(abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, address(liquidBtc), liquidBtcBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(liquidModule)), setLiquidBtcQueueLiquidModule, "0", true)));
        
        return txs;
    }
}