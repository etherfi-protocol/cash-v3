// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SupportEurc is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address eurc = 0x174d1A887e971f7d0fe5C68b328c30e0ED743160;
    address newEurc = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address eurcUsdOracle = 0x8d60a2B5E87ac714F2Bba57140981B79440E5feF;
    uint64 borrowApyPerSecond = 126839167935; // 4% / (365 days in seconds)
    
    address debtManager;
    address priceProvider;
    address cashModule;
    address cashbackDispatcher;
    
    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

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
        tokens[0] = newEurc;

        bool[] memory enableArray = new bool[](1);
        enableArray[0] = true;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = eurcUsdConfig;

        IDebtManager.CollateralTokenConfig memory eurcConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18, 
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        }); 

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory setEurcPriceProviderConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, priceProviderConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), setEurcPriceProviderConfig, "0", false)));
        
        string memory setEurcConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, newEurc, eurcConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setEurcConfig, "0", false)));

        string memory setEurcBorrowToken = iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, newEurc, borrowApyPerSecond, 10e6));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setEurcBorrowToken, "0", false)));

        string memory configureCashbackToken = iToHex(abi.encodeWithSelector(CashbackDispatcher.configureCashbackToken.selector, tokens, enableArray));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashbackDispatcher), configureCashbackToken, "0", false)));

        string memory configureCashModule = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, tokens, enableArray));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), configureCashModule, "0", false)));
        
        txs = appendRemoveOldEurcTx(txs);

        vm.createDir("./output", true);
        string memory path = "./output/SupportEurc.json";
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        assert(IDebtManager(debtManager).isCollateralToken(newEurc) == true);
        assert(IDebtManager(debtManager).isBorrowToken(newEurc) == true);
        assert(CashbackDispatcher(cashbackDispatcher).isCashbackToken(newEurc) == true);
    }

    function appendRemoveOldEurcTx(string memory txs) internal view returns (string memory) {
        address[] memory oldEurcArray = new address[](1);
        oldEurcArray[0] = eurc;
        
        bool[] memory oldEnableArray = new bool[](1);
        oldEnableArray[0] = false;

        PriceProvider.Config memory oldEurcUsdConfig;
        PriceProvider.Config[] memory oldPriceProviderConfigs = new PriceProvider.Config[](1);
        oldPriceProviderConfigs[0] = oldEurcUsdConfig;

        string memory removeOldEurcBorrowToken = iToHex(abi.encodeWithSelector(IDebtManager.unsupportBorrowToken.selector, eurc));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), removeOldEurcBorrowToken, "0", false)));

        string memory removeOldEurcCollateralToken = iToHex(abi.encodeWithSelector(IDebtManager.unsupportCollateralToken.selector, eurc));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), removeOldEurcCollateralToken, "0", false)));

        string memory removeOldEurcPriceProviderConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, oldEurcArray, oldPriceProviderConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), removeOldEurcPriceProviderConfig, "0", false)));

        string memory removeOldEurcCashbackToken = iToHex(abi.encodeWithSelector(CashbackDispatcher.configureCashbackToken.selector, oldEurcArray, oldEnableArray));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashbackDispatcher), removeOldEurcCashbackToken, "0", false)));

        string memory removeOldEurcCashModule = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, oldEurcArray, oldEnableArray));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), removeOldEurcCashModule, "0", true)));

        return txs;
    }
}