// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IAggregatorV3, PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../../src/interfaces/ILayerZeroTeller.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract ConfigureOptimismProdEusd is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // eUSD
    address constant eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant eUsdTeller = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;

    // Liquid assets + tellers (same as Scroll)
    address constant liquidEth = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant liquidEthTeller = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant liquidUsdTeller = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant liquidBtc = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant liquidBtcTeller = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant ebtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant ebtcTeller = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;

    // Boring queues
    address constant liquidEthBoringQueue = 0x0D2dF071207E18Ca8638b4f04E98c53155eC2cE0;
    address constant liquidBtcBoringQueue = 0x77A2fd42F8769d8063F2E75061FC200014E41Edf;
    address constant liquidUsdBoringQueue = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
    address constant ebtcBoringQueue = 0x686696A3e59eE16e8A8533d84B62cfA504827135;

    address priceProvider;
    address debtManager;
    address dataProvider;
    address cashModule;
    address liquifierProxy;
    address liquidModule;
    address liquidModuleWithReferrer;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        priceProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider"));
        debtManager = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));
        dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        cashModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule"));
        liquifierProxy = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "LiquidUSDLiquifierModule"));
        liquidModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiLiquidModule"));
        liquidModuleWithReferrer = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiLiquidModuleWithReferrer"));

        vm.startBroadcast();

        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        txs = _buildOracleTx(txs);
        txs = _buildCollateralTx(txs);
        txs = _buildModuleConfigTxs(txs);
        txs = _buildLiquidAssetsOnReferrerTxs(txs);

        vm.stopBroadcast();

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureOptimismProdEusd.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);

        // Assertions
        assert(PriceProvider(priceProvider).price(eUsd) != 0);
        assert(IDebtManager(debtManager).isCollateralToken(eUsd));
        assert(EtherFiDataProvider(dataProvider).isDefaultModule(liquifierProxy));

        console.log("All assertions passed!");
    }

    function _buildOracleTx(string memory txs) internal view returns (string memory) {
        AccountantWithRateProviders eUsdAccountant = ILayerZeroTeller(eUsdTeller).accountant();

        address[] memory tokens = new address[](1);
        tokens[0] = eUsd;

        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: address(eUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: eUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(priceProvider),
            iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, configs)),
            "0", false
        )));

        return txs;
    }

    function _buildCollateralTx(string memory txs) internal view returns (string memory) {
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, eUsd,
                IDebtManager.CollateralTokenConfig({ltv: 80e18, liquidationThreshold: 90e18, liquidationBonus: 2e18}))),
            "0", false
        )));

        return txs;
    }

    function _buildModuleConfigTxs(string memory txs) internal view returns (string memory) {
        // Whitelist LiquidUSDLiquifier as default module
        address[] memory modules = new address[](1);
        modules[0] = liquifierProxy;

        bool[] memory enable = new bool[](1);
        enable[0] = true;

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(dataProvider),
            iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, enable)),
            "0", false
        )));

        // Configure EtherFiLiquidModule to request withdrawals
        address[] memory withdrawModules = new address[](1);
        withdrawModules[0] = liquidModule;

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(cashModule),
            iToHex(abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, withdrawModules, enable)),
            "0", false
        )));

        return txs;
    }

    function _buildLiquidAssetsOnReferrerTxs(string memory txs) internal view returns (string memory) {
        // Add all 5 liquid assets to EtherFiLiquidModuleWithReferrer
        address[] memory assets = new address[](5);
        assets[0] = eUsd;
        assets[1] = liquidEth;
        assets[2] = liquidBtc;
        assets[3] = liquidUsd;
        assets[4] = ebtc;

        address[] memory tellers = new address[](5);
        tellers[0] = eUsdTeller;
        tellers[1] = liquidEthTeller;
        tellers[2] = liquidBtcTeller;
        tellers[3] = liquidUsdTeller;
        tellers[4] = ebtcTeller;

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModuleWithReferrer),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModuleWithReferrer.addLiquidAssets.selector, assets, tellers)),
            "0", false
        )));

        // Set boring queues for liquidEth, liquidBtc, liquidUsd, ebtc
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModuleWithReferrer),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModuleWithReferrer.setLiquidAssetWithdrawQueue.selector, liquidEth, liquidEthBoringQueue)),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModuleWithReferrer),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModuleWithReferrer.setLiquidAssetWithdrawQueue.selector, liquidBtc, liquidBtcBoringQueue)),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModuleWithReferrer),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModuleWithReferrer.setLiquidAssetWithdrawQueue.selector, liquidUsd, liquidUsdBoringQueue)),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModuleWithReferrer),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModuleWithReferrer.setLiquidAssetWithdrawQueue.selector, ebtc, ebtcBoringQueue)),
            "0", true
        )));

        return txs;
    }
}
