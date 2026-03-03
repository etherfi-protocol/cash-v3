// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { ChainConfig, Utils } from "./utils/Utils.sol";

contract DeployMidasModule is Utils {
    address midasToken = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address usdt = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;

    address depositVault = 0xcA1C871f8ae2571Cb126A46861fc06cB9E645152;
    address redemptionVault = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    address midasPriceOracle = 0xB2a4eC4C9b95D7a87bA3989d0FD38dFfDd944A24;

    IDebtManager debtManager;
    PriceProvider priceProvider;
    ICashModule cashModule;
    address dataProvider;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        dataProvider = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider")));

        priceProvider = PriceProvider(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider")));

        debtManager = IDebtManager(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager")));

        cashModule = ICashModule(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule")));

        // Prepare arrays for Midas module deployment
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = midasToken;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = depositVault;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = redemptionVault;

        //deploy Midas module
        MidasModule midasModule = new MidasModule(
            dataProvider,
            midasTokens,
            depositVaults,
            redemptionVaults
        );

        address[] memory defaultModules = new address[](1);
        defaultModules[0] = address(midasModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        //configure default module in data provider
        EtherFiDataProvider(dataProvider).configureDefaultModules(defaultModules, shouldWhitelist);

        address[] memory tokens = new address[](1);
        tokens[0] = midasToken;

        PriceProvider.Config memory midasConfig = PriceProvider.Config({
            oracle: midasPriceOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true, //chainlink type oracle
            oraclePriceDecimals: IAggregatorV3(midasPriceOracle).decimals(),
            maxStaleness: 30 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });
        PriceProvider.Config[] memory midasConfigs = new PriceProvider.Config[](1);
        midasConfigs[0] = midasConfig;

        //price provider set oracle
        PriceProvider(priceProvider).setTokenConfig(tokens, midasConfigs);

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18,
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18 //confirmed with team
        });

        uint64 borrowApy = 1; // ~0%
        uint128 minShares = type(uint128).max; // Since we dont want to use it in borrow mode

        //debt manager set collateral and borrow config
        debtManager.supportCollateralToken(address(midasToken), collateralConfig);
        debtManager.supportBorrowToken(address(midasToken), borrowApy, minShares);

        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = address(midasToken);

        //cash module set withdrawable asset
        ICashModule(cashModule).configureWithdrawAssets(withdrawableAssets, shouldWhitelist);

        vm.stopBroadcast();
    }
}
