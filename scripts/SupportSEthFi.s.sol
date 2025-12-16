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

interface ISEthFiOracle {
    function latestAnswer() external view returns (int256);
}

contract SetsETHFIConfig is Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    //Todo: Cross check Addresses
    address sETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address sEthFiUSDOracle = 0xeA99E12b06C1606FCae968Cc6ceBB1A7A323E0f5;
    address sETHFITeller = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;
    address sETHFIBoringQueue = 0xF03352da1536F31172A7F7cB092D4717DeDDd3CB;

    address debtManager;
    address priceProvider;
    address cashModule;
    address liquidModule;


    function run() public {
        string memory chainId = vm.toString(block.chainid);
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

        liquidModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiLiquidModule")
        );

        // Configure sETHFI price oracle
        PriceProvider.Config memory sEthFiUSDConfig = PriceProvider.Config({
            oracle: sEthFiUSDOracle,
            priceFunctionCalldata: abi.encodeWithSelector(ISEthFiOracle.latestAnswer.selector),
            isChainlinkType: false,
            oraclePriceDecimals: IAggregatorV3(sEthFiUSDOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](1);
        tokens[0] = sETHFI;

        PriceProvider.Config[]
            memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = sEthFiUSDConfig;

        // Configure sETHFI as collateral in Debt Manager
        IDebtManager.CollateralTokenConfig memory sETHFIConfig = IDebtManager
            .CollateralTokenConfig({
                ltv: 20e18,
                liquidationThreshold: 50e18,
                liquidationBonus: 5e18
            });

        PriceProvider(priceProvider).setTokenConfig(tokens, priceProviderConfigs);

        IDebtManager(debtManager).supportCollateralToken(sETHFI, sETHFIConfig);

        address[] memory sETHFIArray = new address[](1);
        sETHFIArray[0] = sETHFI;

        bool[] memory enableArray = new bool[](1);
        enableArray[0] = true;

        address[] memory sETHFITellerArray = new address[](1);
        sETHFITellerArray[0] = sETHFITeller;

        ICashModule(cashModule).configureWithdrawAssets(sETHFIArray, enableArray);

        EtherFiLiquidModule(liquidModule).addLiquidAssets(sETHFIArray, sETHFITellerArray);

        EtherFiLiquidModule(liquidModule).setLiquidAssetWithdrawQueue(sETHFI, sETHFIBoringQueue);

        vm.stopBroadcast();
    }
}