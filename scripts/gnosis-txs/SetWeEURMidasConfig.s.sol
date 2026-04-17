// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IAggregatorV3, PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetWeEURMidasConfig is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address constant WEEUR_TOKEN = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address constant PRICE_ORACLE = 0x01b910C1aa51cdC4a2a84d76CB255C4974Bf8A19;

    address constant midasModule = 0x2D43400058cE6810916Fd312FB38a7DcdF9708aa;

    IDebtManager debtManager;
    PriceProvider priceProvider;
    ICashModule cashModule;
    address dataProvider;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        dataProvider = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider")));
        priceProvider = PriceProvider(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider")));
        debtManager = IDebtManager(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager")));
        cashModule = ICashModule(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule")));

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // 1. Whitelist as default module in DataProvider
        address[] memory defaultModules = new address[](1);
        defaultModules[0] = midasModule;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory configureDefaultModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, defaultModules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureDefaultModules, "0", false)));

        // 2. Configure price oracle
        address[] memory tokens = new address[](1);
        tokens[0] = WEEUR_TOKEN;

        PriceProvider.Config memory oracleConfig = PriceProvider.Config({
            oracle: PRICE_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(PRICE_ORACLE).decimals(),
            maxStaleness: 6 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = oracleConfig;

        string memory setTokenConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, configs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(priceProvider)), setTokenConfig, "0", false)));

        // 3. Configure collateral in DebtManager
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 75e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 2e18
        });

        string memory supportCollateralToken = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, WEEUR_TOKEN, collateralConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), supportCollateralToken, "0", false)));

        // 4. Allow withdrawal via CashModule
        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = WEEUR_TOKEN;

        string memory configureWithdrawAssets = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, withdrawableAssets, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(cashModule)), configureWithdrawAssets, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/SetWeEURMidasConfig.json";
        vm.writeFile(path, txs);

        // Test execution
        executeGnosisTransactionBundle(path);

        assert(EtherFiDataProvider(dataProvider).isDefaultModule(midasModule) == true);
        assert(IDebtManager(debtManager).isCollateralToken(WEEUR_TOKEN) == true);
    }
}
