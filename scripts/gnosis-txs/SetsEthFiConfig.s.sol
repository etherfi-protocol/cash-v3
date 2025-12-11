// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import {IDebtManager} from "../../src/interfaces/IDebtManager.sol";
import {ICashModule} from "../../src/interfaces/ICashModule.sol";
import {EtherFiLiquidModule} from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import {PriceProvider, IAggregatorV3} from "../../src/oracle/PriceProvider.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";
import {Utils} from "../utils/Utils.sol";

contract SetsETHFIConfig is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    //Todo: Cross check Addresses
    address sETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address sEthFiUSDOracle = 0x0000000000000000000000000000000000000000;
    address sETHFITeller = 0xe2acf9f80a2756E51D1e53F9f41583C84279Fb1f;
    address sETHFIBoringQueue = 0xF03352da1536F31172A7F7cB092D4717DeDDd3CB;

    address debtManager;
    address priceProvider;


    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

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
            priceFunctionCalldata: "",
            isChainlinkType: true,
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

        // Create Gnosis transaction bundle
        string memory txs = _getGnosisHeader(
            chainId,
            addressToHex(cashControllerSafe)
        );

        // Price Provider tx for setting sETHFI oracle
        string memory setsETHFIPriceProviderConfig = iToHex(
            abi.encodeWithSelector(
                PriceProvider.setTokenConfig.selector,
                tokens,
                priceProviderConfigs
            )
        );

        // Debt Manager tx for supporting sETHFI as collateral
        string memory setsETHFIConfig = iToHex(
            abi.encodeWithSelector(
                IDebtManager.supportCollateralToken.selector,
                sETHFI,
                sETHFIConfig
            )
        );


        // Cash Module tx for configuring withdraw asset
        string memory sETHFICashModuleConfig = iToHex(
            abi.encodeWithSelector(
                ICashModule.configureWithdrawAsset.selector,
                sETHFI,
                true
            )
        );

        // Liquid Module tx for adding liquid asset
        string memory sETHFILiquidModuleConfig = iToHex(
            abi.encodeWithSelector(
                EtherFiLiquidModule.addLiquidAssets.selector,
                sETHFI,
                sETHFITeller
            )
        );

        // Liquid Module tx for setting withdraw queue
        string memory sETHFILiquidModuleWithdrawQueueConfig = iToHex(
            abi.encodeWithSelector(
                EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector,
                sETHFI,
                sETHFIBoringQueue
            )
        );



        // Added Price Provider transaction to bundle
        txs = string(
            abi.encodePacked(
                txs,
                _getGnosisTransaction(
                    addressToHex(priceProvider),
                    setsETHFIPriceProviderConfig,
                    "0",
                    false
                )
            )
        );

        // Added Debt Manager transaction to bundle
        txs = string(
            abi.encodePacked(
                txs,
                _getGnosisTransaction(
                    addressToHex(debtManager),
                    setsETHFIConfig,
                    "0",
                    true
                )
            )
        );

        // Added Cash Module transaction to bundle
        txs = string(
            abi.encodePacked(
                txs,
                _getGnosisTransaction(
                    addressToHex(cashModule),
                    sETHFICashModuleConfig,
                    "0",
                    false
                )
            )
        );

        // Added Liquid Module withdraw queue transaction to bundle
        txs = string(
            abi.encodePacked(
                txs,
                _getGnosisTransaction(
                    addressToHex(liquidModule),
                    sETHFILiquidModuleConfig,
                    "0",
                    true
                )
            )
        );

        // Added Liquid Module withdraw queue transaction to bundle
        txs = string(
            abi.encodePacked(
                txs,
                _getGnosisTransaction(
                    addressToHex(liquidModule),
                    sETHFILiquidModuleWithdrawQueueConfig,
                    "0",
                    true
                )
            )
        ); 

        vm.createDir("./output", true);
        string memory path = "./output/SetsETHFIConfig.json";
        vm.writeFile(path, txs);
    }
}
