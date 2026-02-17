// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import {IDebtManager} from "../src/interfaces/IDebtManager.sol";
import {ICashModule} from "../src/interfaces/ICashModule.sol";
import {EtherFiLiquidModule} from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import {PriceProvider, IAggregatorV3} from "../src/oracle/PriceProvider.sol";
import {Utils} from "./utils/Utils.sol";

contract SupportEurc is Utils, Test {
    address eurc = 0x174d1A887e971f7d0fe5C68b328c30e0ED743160;
    address eurcUsdOracle = 0x8d60a2B5E87ac714F2Bba57140981B79440E5feF;
    uint64 borrowApyPerSecond = 317097919837; // 10% / (365 days in seconds)

    address debtManager;
    address priceProvider;
    address cashModule;


    function run() public {
        string memory deployments = readDeploymentFile();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // Load deployed contract addresses
        priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );

        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        PriceProvider.Config memory eurcUsdConfig = PriceProvider.Config({
            oracle: eurcUsdOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(eurcUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](1);
        tokens[0] = eurc;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = eurcUsdConfig;

        // Configure eurc as collateral in Debt Manager
        IDebtManager.CollateralTokenConfig memory eurcConfig = IDebtManager
            .CollateralTokenConfig({
                ltv: 90e18,
                liquidationThreshold: 95e18,
                liquidationBonus: 1e18
            });

        PriceProvider(priceProvider).setTokenConfig(tokens, priceProviderConfigs);

        IDebtManager(debtManager).supportCollateralToken(eurc, eurcConfig);

        IDebtManager(debtManager).supportBorrowToken(eurc, borrowApyPerSecond, 10e6);

        address[] memory eurcArray = new address[](1);
        eurcArray[0] = eurc;

        bool[] memory enableArray = new bool[](1);
        enableArray[0] = true;

        ICashModule(cashModule).configureWithdrawAssets(eurcArray, enableArray);

        vm.stopBroadcast();
    }
}