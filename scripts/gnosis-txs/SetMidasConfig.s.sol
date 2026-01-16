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

contract SetMidasConfig is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address midasToken = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address midasPriceOracle = 0xB2a4eC4C9b95D7a87bA3989d0FD38dFfDd944A24;

    // Set this to the deployed MidasModule address after deployment
    // If the address is in the deployments file under "MidasModule", it will be read automatically
    address midasModule = 0xEE3Fb6914105BA01196ab26191C3BB7448016467;

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

        // Generate Gnosis transactions
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // Configure default module in data provider
        address[] memory defaultModules = new address[](1);
        defaultModules[0] = midasModule;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory configureDefaultModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, defaultModules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureDefaultModules, "0", false)));

        // Set price provider config
        address[] memory tokens = new address[](1);
        tokens[0] = midasToken;

        PriceProvider.Config memory midasConfig = PriceProvider.Config({
            oracle: midasPriceOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true, // chainlink type oracle
            oraclePriceDecimals: IAggregatorV3(midasPriceOracle).decimals(),
            maxStaleness: 6 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        PriceProvider.Config[] memory midasConfigs = new PriceProvider.Config[](1);
        midasConfigs[0] = midasConfig;

        string memory setTokenConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, midasConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(priceProvider)), setTokenConfig, "0", false)));

        // Set collateral and borrow config in debt manager
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 2e18 // same as liquid USD
        });

        uint64 borrowApy = 1; // ~0%
        uint128 minShares = type(uint128).max; // Since we dont want to use it in borrow mode

        string memory supportCollateralToken = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, midasToken, collateralConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), supportCollateralToken, "0", false)));

        string memory supportBorrowToken = iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, midasToken, borrowApy, minShares));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), supportBorrowToken, "0", false)));

        // Configure withdrawable assets in cash module
        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = midasToken;

        string memory configureWithdrawAssets = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, withdrawableAssets, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(cashModule)), configureWithdrawAssets, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/SetMidasConfig.json";
        vm.writeFile(path, txs);

        // Test execution
        executeGnosisTransactionBundle(path);

        assert(EtherFiDataProvider(dataProvider).isDefaultModule(midasModule) == true);
        assert(IDebtManager(debtManager).isCollateralToken(midasToken) == true);
    }
}
