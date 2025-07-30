// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import  "forge-std/Vm.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import {Test} from "forge-std/Test.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SettlementDispatcher} from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";

contract UpgradeSettlementDispatcher is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address constant settlementDispatcherReapImpl = 0xD7C422a48ecE1a5f883593d6d1CcB7A5dD486a3f;
    address constant settlementDispatcherRainImpl = 0x49859E57be078A0b9A396CBBf1B5197D13caEE92;

    address mainnetSettlementAddress = 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4;

    IERC20 public usdtScroll = IERC20(0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df);
    IERC20 public usdcScroll = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);

    address public owner = 0x23ddE38BA34e378D28c667bC26b44310c7CA0997;

    // https://docs.chain.link/data-feeds/price-feeds/addresses?page=1&testnetPage=1&network=scroll&testnetSearch=E&search=USDT
    address usdtUsdOracle = 0xf376A91Ae078927eb3686D6010a6f1482424954E;

    address debtManager;
    address priceProvider;

    function run() public {

        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address settlementDispatcherReap = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherReap"))
        );
        address settlementDispatcherRain = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherRain"))
        );
        priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );
        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe)); 

        PriceProvider.Config memory usdtUsdConfig = PriceProvider.Config({
            oracle: usdtUsdOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdtUsdOracle).decimals(),
            maxStaleness: 10 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdtScroll); 
        uint64 borrowApy = 1;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = usdtUsdConfig;

        IDebtManager.CollateralTokenConfig memory usdtConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18,
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        }); 

        // set usdt spend+borrow configs
        string memory setusdtPriceProviderConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, priceProviderConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), setusdtPriceProviderConfig, "0", false)));
        
        string memory setUsdtConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, address(usdtScroll), usdtConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setUsdtConfig, "0", false)));

        string memory setUsdtBorrowConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, address(usdtScroll), borrowApy, type(uint128).max));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setUsdtBorrowConfig, "0", false)));

        // upgrade settlement dispatchers
        string memory upgradeTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherReapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherReap)), upgradeTransaction, "0", false)));

        upgradeTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherRainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherRain)), upgradeTransaction, "0", false)));


        address[] memory SettlementDispatcherTokens = new address[](2); 
        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](2);
        SettlementDispatcherTokens[0] = address(usdtScroll);
        SettlementDispatcherTokens[1] = address(usdcScroll);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: mainnetSettlementAddress,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });
        destDatas[1] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: mainnetSettlementAddress,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });

        // set destination data
        string memory setDestinationData = iToHex(abi.encodeWithSelector(SettlementDispatcher.setDestinationData.selector, SettlementDispatcherTokens, destDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherReap)), setDestinationData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherRain)), setDestinationData, "0", true)));

        string memory path = string.concat("./output/UpgradeSettlementDispatchers-SetUsdtConfig-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);

        vm.startPrank(owner);

        deal(address(usdtScroll), address(settlementDispatcherRain), 1e6);
        SettlementDispatcher(payable(settlementDispatcherRain)).bridge(address(usdtScroll), 1e6, 1);
        assertEq(usdtScroll.balanceOf(address(settlementDispatcherRain)), 0);

        deal(address(usdtScroll), address(settlementDispatcherReap), 1e6);
        SettlementDispatcher(payable(settlementDispatcherReap)).bridge(address(usdtScroll), 1e6, 1);
        assertEq(usdtScroll.balanceOf(address(settlementDispatcherReap)), 0);

        deal(address(usdcScroll), address(settlementDispatcherRain), 1e6);
        SettlementDispatcher(payable(settlementDispatcherRain)).bridge(address(usdcScroll), 1e6, 1);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherRain)), 0);

        deal(address(usdcScroll), address(settlementDispatcherReap), 1e6);
        SettlementDispatcher(payable(settlementDispatcherReap)).bridge(address(usdcScroll), 1e6, 1);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), 0);

        assert(IDebtManager(debtManager).isCollateralToken(address(usdtScroll)) == true);
        assert(IDebtManager(debtManager).isBorrowToken(address(usdtScroll)) == true);
    }

}
