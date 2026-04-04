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
import { ILayerZeroTeller, AccountantWithRateProviders } from "../../src/interfaces/ILayerZeroTeller.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract ConfigureOptimismProdEusd is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // eUSD
    address constant eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant eUsdTeller = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;

    address priceProvider;
    address debtManager;
    address dataProvider;
    address cashModule;
    address liquifierProxy;
    address liquidModule;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        priceProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider"));
        debtManager = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));
        dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        cashModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule"));
        liquifierProxy = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "LiquidUSDLiquifierModule"));
        liquidModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiLiquidModule"));

        vm.startBroadcast();

        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        txs = _buildOracleTx(txs);
        txs = _buildCollateralTx(txs);
        txs = _buildModuleConfigTxs(txs);

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
            "0", true
        )));

        return txs;
    }
}
