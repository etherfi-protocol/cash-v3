// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { FraxModule } from "../src/modules/frax/FraxModule.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { ChainConfig, Utils } from "./utils/Utils.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";

contract DeployFraxModule is Utils {
    address fraxusd = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address custodian = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    address fraxUsdPriceOracle = 0xf376A91Ae078927eb3686D6010a6f1482424954E; //currently USDT/USD oracle

    IDebtManager debtManager;
    PriceProvider priceProvider;
    ICashModule cashModule;


    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider")));

        priceProvider = PriceProvider(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider")));

        debtManager = IDebtManager(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager")));

        cashModule = ICashModule(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule")));

        //deploy frax module
        FraxModule fraxModule = new FraxModule(fraxusd, usdc, _etherFiDataProvider, custodian);

        address[] memory defaultModules = new address[](1);
        defaultModules[0] = address(fraxModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        //configure default module in data provider
        EtherFiDataProvider(dataProvider).configureDefaultModules(defaultModules, shouldWhitelist);

        address[] memory tokens = new address[](1);
        tokens[0] = fraxusd;

        PriceProvider.Config memory fraxUsdConfig = PriceProvider.Config({ oracle: fraxUsdPriceOracle, priceFunctionCalldata: "", isChainlinkType: true, oraclePriceDecimals: IAggregatorV3(fraxUsdPriceOracle).decimals(), maxStaleness: 2 days, dataType: PriceProvider.ReturnType.Int256, isBaseTokenEth: false, isStableToken: true, isBaseTokenBtc: false });

        //price provider set oracle
        PriceProvider(priceProvider).setTokenConfig(tokens, fraxUsdConfig);

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            //Todo: adjust these values if required
            ltv: 90e18,
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        });

        uint64 borrowApy = 1; // ~0%
        uint128 minShares = type(uint128).max; // Since we dont want to use it in borrow mode

        //debt manager set collateral and borrow config
        debtManager.supportCollateralToken(address(fraxusd), collateralConfig);
        debtManager.supportBorrowToken(address(fraxusd), borrowApy, minShares);


        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = address(fraxusd);

        bool [] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        //cash module set withdrawable asset
        ICashModule(cashModule).configureWithdrawAssets(withdrawableAssets, shouldWhitelist);

        vm.stopBroadcast();
    }
}
