// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import {IDebtManager} from "../src/interfaces/IDebtManager.sol";
import {ICashModule} from "../src/interfaces/ICashModule.sol";
import {CashbackDispatcher} from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import {EtherFiLiquidModule} from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import {PriceProvider, IAggregatorV3} from "../src/oracle/PriceProvider.sol";
import {Utils} from "./utils/Utils.sol";

contract RemoveSupportEurc is Utils, Test {
    address eurcDeployedByScroll = 0x174d1A887e971f7d0fe5C68b328c30e0ED743160;

    address debtManager;
    address priceProvider;
    address cashModule;
    address cashbackDispatcher;


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

        cashbackDispatcher = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashbackDispatcher")
        );

        PriceProvider.Config memory eurcUsdConfig;

        address[] memory tokens = new address[](1);
        tokens[0] = eurcDeployedByScroll;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = eurcUsdConfig;

        // Configure eurc as collateral in Debt Manager
        IDebtManager.CollateralTokenConfig memory eurcConfig = IDebtManager
            .CollateralTokenConfig({
                ltv: 90e18,
                liquidationThreshold: 95e18,
                liquidationBonus: 1e18
            });

        IDebtManager(debtManager).unsupportBorrowToken(eurcDeployedByScroll);
        IDebtManager(debtManager).unsupportCollateralToken(eurcDeployedByScroll);
        PriceProvider(priceProvider).setTokenConfig(tokens, priceProviderConfigs);


        address[] memory eurcArray = new address[](1);
        eurcArray[0] = eurcDeployedByScroll;

        bool[] memory enableArray = new bool[](1);
        enableArray[0] = false;

        CashbackDispatcher(cashbackDispatcher).configureCashbackToken(eurcArray, enableArray);

        ICashModule(cashModule).configureWithdrawAssets(eurcArray, enableArray);

        vm.stopBroadcast();
    }
}