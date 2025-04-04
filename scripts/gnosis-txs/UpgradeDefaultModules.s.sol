// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory, BeaconFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeDefaultModules is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    IERC20 public liquidEth = IERC20(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    ILayerZeroTeller public liquidEthTeller = ILayerZeroTeller(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    ILayerZeroTeller public liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
    IERC20 public liquidBtc = IERC20(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    ILayerZeroTeller public liquidBtcTeller = ILayerZeroTeller(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);

    IERC20 public eUsd = IERC20(0x939778D83b46B456224A33Fb59630B11DEC56663);
    ILayerZeroTeller public eUsdTeller = ILayerZeroTeller(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA);

    IERC20 public weth = IERC20(0x5300000000000000000000000000000000000004);
    IERC20 public weEth = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    address weEthSyncPool = 0x750cf0fd3bc891D8D864B732BC4AD340096e5e68;
    address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    address factory;
    address dataProvider;
    address cashModule;

    EtherFiSafe randomSafe = EtherFiSafe(payable(0x4ECF024b92f36C27F487dcb88cF109A6704ED643));

    EtherFiDataProvider dataProviderImpl;
    EtherFiSafe safeImpl;
    EtherFiStakeModule stakeModule;
    EtherFiLiquidModule liquidModule;
    OpenOceanSwapModule swapModule;
    string chainId;
    string deployments;

    function run() public {
        deployments = readDeploymentFile();

        chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        factory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiSafeFactory")
        );
        
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        dataProviderImpl = new EtherFiDataProvider();
        safeImpl = new EtherFiSafe(dataProvider);
        stakeModule = new EtherFiStakeModule(dataProvider, weEthSyncPool, address(weth), address(weEth));

        address[] memory assets = new address[](4);
        assets[0] = address(liquidEth);
        assets[1] = address(liquidBtc);
        assets[2] = address(liquidUsd);
        assets[3] = address(eUsd);
        
        address[] memory tellers = new address[](4);
        tellers[0] = address(liquidEthTeller);
        tellers[1] = address(liquidBtcTeller);
        tellers[2] = address(liquidUsdTeller);
        tellers[3] = address(eUsdTeller);
        
        liquidModule = new EtherFiLiquidModule(assets, tellers, address(dataProvider), address(weth));
        swapModule = new OpenOceanSwapModule(openOceanSwapRouter, dataProvider);

        string memory txs = getGnosisTransactions();

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeDefaultModules.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        assert(randomSafe.isModuleEnabled(cashModule) == true);
        assert(randomSafe.isModuleEnabled(address(liquidModule)) == true);
        assert(randomSafe.isModuleEnabled(address(stakeModule)) == true);
        assert(randomSafe.isModuleEnabled(address(swapModule)) == true);
    }

    function getGnosisTransactions() internal view returns (string memory) {
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory dataProviderUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, dataProviderImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), dataProviderUpgrade, false)));

        string memory safeImplUpgrade = iToHex(abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, safeImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(factory), safeImplUpgrade, false)));

                address[] memory defaultModules = new address[](4);
        defaultModules[0] = cashModule;
        defaultModules[1] = address(liquidModule);
        defaultModules[2] = address(stakeModule);
        defaultModules[3] = address(swapModule);

        bool[] memory shouldWhitelist = new bool[](4);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;
        shouldWhitelist[2] = true;
        shouldWhitelist[3] = true;

        string memory addDefaultModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, defaultModules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), addDefaultModules, false)));

        address[] memory dewhitelistModules = new address[](1);
        dewhitelistModules[0] = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "OpenOceanSwapModule")
        );

        bool[] memory dewhitelistModuleShouldWhitelist = new bool[](1);
        dewhitelistModuleShouldWhitelist[0] = false;        

        string memory removeOldOpenOceanModule = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, dewhitelistModules, dewhitelistModuleShouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), removeOldOpenOceanModule, true)));

        return txs;
    }
}