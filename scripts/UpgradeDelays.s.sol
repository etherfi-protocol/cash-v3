// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiStakeModule } from "../src/modules/etherfi/EtherFiStakeModule.sol";
import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { StargateModule } from "../src/modules/stargate/StargateModule.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { CashModuleStorageContract } from "../src/modules/cash/CashModuleStorageContract.sol";
import { CashModuleCore } from "../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { CashLens } from "../src/modules/cash/CashLens.sol";
import { Utils, ChainConfig } from "./utils/Utils.sol";

contract UpgradeDelays is Utils {
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

    address cashModuleCoreImpl;
    address cashModuleSettersImpl;
    address cashLensImpl;
    address cashEventEmitterImpl;
    address stakeModule;
    address liquidModule;
    address openOceanModule;
    address stargateModule;

    address dataProvider;
    address cashModule;
    address cashEventEmitter;
    address cashLens;
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        cashModule = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashModule"))
        );

        cashEventEmitter = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashEventEmitter"))
        );

        cashLens = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashLens"))
        );

        deployNewImplementations();

        address[] memory modules = new address[](4);
        modules[0] = address(stargateModule);
        modules[1] = address(stakeModule);
        modules[2] = address(liquidModule);
        modules[3] = address(openOceanModule);

        bool[] memory isDefaultModule = new bool[](4);
        isDefaultModule[0] = true;
        isDefaultModule[1] = true;
        isDefaultModule[2] = true;
        isDefaultModule[3] = true;

        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, isDefaultModule);
        
        UUPSUpgradeable(cashModule).upgradeToAndCall(cashModuleCoreImpl, "");
        CashModuleCore(cashModule).setCashModuleSettersAddress(cashModuleSettersImpl);
        UUPSUpgradeable(cashLens).upgradeToAndCall(cashLensImpl, "");
        UUPSUpgradeable(cashEventEmitter).upgradeToAndCall(cashEventEmitterImpl, "");

        address[] memory modulesCanRequestWitdraw = new address[](2);
        modulesCanRequestWitdraw[0] = stargateModule;
        modulesCanRequestWitdraw[1] = liquidModule;

        bool[] memory canRequestWithdraw = new bool[](2);
        canRequestWithdraw[0] = true;
        canRequestWithdraw[1] = true;

        CashModuleSetters(cashModule).configureModulesCanRequestWithdraw(modulesCanRequestWitdraw, canRequestWithdraw);

        EtherFiLiquidModule(liquidModule).setLiquidAssetWithdrawQueue(address(liquidUsd), liquidUsdBoringQueue);
        EtherFiLiquidModule(liquidModule).setLiquidAssetWithdrawQueue(address(liquidBtc), liquidBtcBoringQueue);
        EtherFiLiquidModule(liquidModule).setLiquidAssetWithdrawQueue(address(liquidEth), liquidEthBoringQueue);

        vm.stopBroadcast();
    }

    function deployNewImplementations() internal {
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

        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        cashLensImpl = address(new CashLens(cashModule, dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        stakeModule = address(new EtherFiStakeModule(dataProvider, syncPool, weth, weETH));
        liquidModule = address(new EtherFiLiquidModule(liquidAssets, liquidTellers, dataProvider, weth));
        openOceanModule = address(new OpenOceanSwapModule(openOceanSwapRouter, dataProvider));
        stargateModule = address(new StargateModule(stargateAssets, stargateAssetConfigs, dataProvider));
    }
}

contract RollbackDelaysUpgrade is Utils {
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

    address cashModuleCoreImpl = 0x04a5136B0450C7a8140edf188BB13Ec327D227f7;
    address cashModuleSettersImpl = 0x351Eb26D2Ca2C9c6E682317cF25A15Beb5235463;
    address cashLensImpl = 0xF4C38737d429F15ecEc286D5ae6B131Fe53b0A60;
    address cashEventEmitterImpl = 0xbE197Af70a011A8A382b4Bc71c04e13c6F1e8276;
    address stakeModule = 0x5ac17A065B0e7070737daAc216B3D97c0c400Eec;
    address liquidModule = 0x585d49f856aD14F37234B42Fc78A8506f7f8e446;
    address openOceanModule = 0x976e56Bb016A39480dD9c5044F52f3766212A376;
    address stargateModule = 0x6c906af3300294317C454A18AC552bAce9a72Fca;

    address dataProvider;
    address cashModule;
    address cashEventEmitter;
    address cashLens;
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        cashModule = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashModule"))
        );

        cashEventEmitter = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashEventEmitter"))
        );

        cashLens = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashLens"))
        );
        
        UUPSUpgradeable(cashModule).upgradeToAndCall(cashModuleCoreImpl, "");
        CashModuleCore(cashModule).setCashModuleSettersAddress(cashModuleSettersImpl);
        UUPSUpgradeable(cashLens).upgradeToAndCall(cashLensImpl, "");
        UUPSUpgradeable(cashEventEmitter).upgradeToAndCall(cashEventEmitterImpl, "");

        vm.stopBroadcast();
    }

    function deployNewImplementations() internal {
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

        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        cashLensImpl = address(new CashLens(cashModule, dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        stakeModule = address(new EtherFiStakeModule(dataProvider, syncPool, weth, weETH));
        liquidModule = address(new EtherFiLiquidModule(liquidAssets, liquidTellers, dataProvider, weth));
        openOceanModule = address(new OpenOceanSwapModule(openOceanSwapRouter, dataProvider));
        stargateModule = address(new StargateModule(stargateAssets, stargateAssetConfigs, dataProvider));
    }
}