// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { FraxModule } from "../src/modules/frax/FraxModule.sol";
import { IAggregatorV3, PriceProviderV2 as PriceProvider } from "../src/oracle/PriceProviderV2.sol";
import { Utils } from "./utils/Utils.sol";

contract DeployFraxModule is Utils {
    address fraxusd = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address custodian = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address fraxUsdPriceOracle = 0x8BF42811876e1B692d0E70F61b80e1fbc68Ef1bf;
    address remoteHop = 0x31D982ebd82Ad900358984bd049207A4c2468640;

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

        //deploy frax module
        FraxModule fraxModule = new FraxModule(dataProvider, fraxusd, custodian, remoteHop);

        address[] memory modules = new address[](1);
        modules[0] = address(fraxModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        //configure default module in data provider
        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, shouldWhitelist);

        address[] memory tokens = new address[](1);
        tokens[0] = fraxusd;

        PriceProvider.Config memory fraxUsdConfig = PriceProvider.Config({
            oracle: fraxUsdPriceOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(fraxUsdPriceOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        PriceProvider.Config[] memory fraxUsdConfigs = new PriceProvider.Config[](1);
        fraxUsdConfigs[0] = fraxUsdConfig;

        //price provider set oracle
        PriceProvider(priceProvider).setTokenConfig(tokens, fraxUsdConfigs);

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18, //confirmed
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        });

        uint64 borrowApy = 1; // ~0%
        uint128 minShares = type(uint128).max; // Since we dont want to use it in borrow mode

        //debt manager set collateral and borrow config (idempotent)
        if (!debtManager.isCollateralToken(fraxusd)) debtManager.supportCollateralToken(fraxusd, collateralConfig);
        if (!debtManager.isBorrowToken(fraxusd)) debtManager.supportBorrowToken(fraxusd, borrowApy, minShares);

        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = address(fraxusd);

        ICashModule(cashModule).configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        //cash module set withdrawable asset
        ICashModule(cashModule).configureWithdrawAssets(withdrawableAssets, shouldWhitelist);

        vm.stopBroadcast();
    }
}
