// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SettlementDispatcherV2, BinSponsor} from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradeSettlementDispatcherEUR is Utils {
    address public constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    uint32 public constant EURC_EID = 30101;
    address public constant EURC_RECIPIENT = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        address settlementDispatcherRain = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherRain"))
        );

        address settlementDispatcherReap = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherReap"))
        );

        address settlementDispatcherCardOrder = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherCardOrder"))
        );

        address settlementDispatcherPix = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherPix"))
        );

        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        address settlementDispatcherRainImpl = address(new SettlementDispatcherV2(BinSponsor.Rain, dataProvider));
        address settlementDispatcherReapImpl = address(new SettlementDispatcherV2(BinSponsor.Reap, dataProvider));
        address settlementDispatcherCardOrderImpl = address(new SettlementDispatcherV2(BinSponsor.CardOrder, dataProvider));
        address settlementDispatcherPixImpl = address(new SettlementDispatcherV2(BinSponsor.PIX, dataProvider));

        UUPSUpgradeable(settlementDispatcherRain).upgradeToAndCall(address(settlementDispatcherRainImpl), "");
        UUPSUpgradeable(settlementDispatcherReap).upgradeToAndCall(address(settlementDispatcherReapImpl), "");
        UUPSUpgradeable(settlementDispatcherCardOrder).upgradeToAndCall(address(settlementDispatcherCardOrderImpl), "");
        UUPSUpgradeable(settlementDispatcherPix).upgradeToAndCall(address(settlementDispatcherPixImpl), "");

        address[] memory tokens = new address[](1);
        tokens[0] = EURC;
        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: EURC_EID,
            destRecipient: EURC_RECIPIENT,
            stargate: address(EURC),
            useCanonicalBridge: false,
            minGasLimit: 0,
            isOFT: true
        });

        SettlementDispatcherV2(payable(settlementDispatcherRain)).setDestinationData(tokens, destDatas);
        SettlementDispatcherV2(payable(settlementDispatcherReap)).setDestinationData(tokens, destDatas);
        SettlementDispatcherV2(payable(settlementDispatcherCardOrder)).setDestinationData(tokens, destDatas);
        SettlementDispatcherV2(payable(settlementDispatcherPix)).setDestinationData(tokens, destDatas);

        vm.stopBroadcast();
    }
}