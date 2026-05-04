// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { ChainConfig, Utils } from "./utils/Utils.sol";

contract SupportLiquidEURC is Utils {
    address liquidEurc = 0xBC43Df01195F5b67243179360189BcA2f86Aa584;
    address eurc = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;

    address liquidEurcDepositVault = 0x8d3702c41aDeB3b6d0C5679899EFcF34AaB07cF2;
    address liquidEurcRedemptionVault = 0x5c33073Ea1D21936d760E32a7A7a748BD21B773E;

    address liquidEurcPriceOracle = 0x41D14b9E948e70549EDa102e0BC49Be0C245BfEf;

    IDebtManager debtManager;
    PriceProvider priceProvider;
    ICashModule cashModule;
    MidasModule midasModule;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        priceProvider = PriceProvider(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider")));

        debtManager = IDebtManager(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager")));

        cashModule = ICashModule(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule")));

        midasModule = MidasModule(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "MidasModule")));

        address[] memory midasTokens = new address[](1);
        midasTokens[0] = liquidEurc;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = liquidEurcDepositVault;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = liquidEurcRedemptionVault;

        midasModule.addMidasVaults(midasTokens, depositVaults, redemptionVaults);

        address[] memory tokens = new address[](1);
        tokens[0] = liquidEurc;

        PriceProvider.Config memory liquidEurcConfig = PriceProvider.Config({
            oracle: liquidEurcPriceOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(liquidEurcPriceOracle).decimals(),
            maxStaleness: 7 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        PriceProvider.Config[] memory priceConfigs = new PriceProvider.Config[](1);
        priceConfigs[0] = liquidEurcConfig;

        priceProvider.setTokenConfig(tokens, priceConfigs);

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 2e18
        });

        uint64 borrowApy = 1; // ~0%
        uint128 minShares = type(uint128).max; // Since we dont want to use it in borrow mode

        debtManager.supportCollateralToken(address(liquidEurc), collateralConfig);
        debtManager.supportBorrowToken(address(liquidEurc), borrowApy, minShares);

        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = address(liquidEurc);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        ICashModule(cashModule).configureWithdrawAssets(withdrawableAssets, shouldWhitelist);

        vm.stopBroadcast();
    }
}