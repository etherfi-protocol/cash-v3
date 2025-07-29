// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { SettlementDispatcher, BinSponsor } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { TopUpDestNativeGateway } from "../src/top-up/TopUpDestNativeGateway.sol";
import { Utils } from "./utils/Utils.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { PriceProvider, IAggregatorV3 } from "../src/oracle/PriceProvider.sol";

contract AddUSDTSupportScroll is Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address usdt = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    uint64 borrowApy = 1; // ~0%
    uint128 minShares = type(uint128).max; // Since we dont want to use it in borrow mode
    
    IDebtManager debtManager;
    SettlementDispatcher settlementDispatcherReap;
    SettlementDispatcher settlementDispatcherRain;
    PriceProvider priceProvider;
    string deployments;

    address destRecipient = 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4; // Ryki Address
    address usdtUsdOracle = 0xf376A91Ae078927eb3686D6010a6f1482424954E;

    function run() public {
        deployments = readDeploymentFile();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        
        debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));
        
        settlementDispatcherReap = SettlementDispatcher(payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        )));

        settlementDispatcherRain = SettlementDispatcher(payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherRain")
        )));

        priceProvider = PriceProvider(payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        )));

        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: usdtUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdtUsdOracle).decimals(),
            maxStaleness: 15 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        address[] memory assets = new address[](1);
        assets[0] = address(usdt);

        priceProvider.setTokenConfig(assets, configs);

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18,
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        });

        debtManager.supportCollateralToken(address(usdt), collateralConfig);
        debtManager.supportBorrowToken(address(usdt), borrowApy, minShares);

        address settlementDispatcherReapImpl = address(new SettlementDispatcher(BinSponsor.Reap, dataProvider));
        address settlementDispatcherRainImpl = address(new SettlementDispatcher(BinSponsor.Rain, dataProvider));

        UUPSUpgradeable(address(settlementDispatcherReap)).upgradeToAndCall(settlementDispatcherReapImpl, "");
        UUPSUpgradeable(address(settlementDispatcherRain)).upgradeToAndCall(settlementDispatcherRainImpl, "");

        SettlementDispatcher.DestinationData[] memory datas = new SettlementDispatcher.DestinationData[](2);
        datas[0] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: destRecipient,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });
        datas[1] = datas[0];

        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = usdt;

        settlementDispatcherReap.setDestinationData(tokens, datas);
        settlementDispatcherRain.setDestinationData(tokens, datas);

        vm.stopBroadcast();
    }
}