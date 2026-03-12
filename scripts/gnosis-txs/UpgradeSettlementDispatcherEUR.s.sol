// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SettlementDispatcherV2, BinSponsor} from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import {Utils, ChainConfig} from "../utils/Utils.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";

// source .env && forge script scripts/gnosis-txs/UpgradeSettlementDispatcherEUR.s.sol:UpgradeSettlementDispatcherEUR --rpc-url $SCROLL_RPC --broadcast -vvvv --verify
contract UpgradeSettlementDispatcherEUR is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    uint32 public constant EURC_EID = 30101;
    address public constant EURC_RECIPIENT = 0x4358f4940283E6357128941a5c508e5F314D79CB;

    address settlementDispatcherRain;
    address settlementDispatcherReap;
    address settlementDispatcherCardOrder;
    address settlementDispatcherPix;
    address settlementDispatcherRainImpl;
    address settlementDispatcherReapImpl;
    address settlementDispatcherCardOrderImpl;
    address settlementDispatcherPixImpl;

    function run() public {
        vm.startBroadcast();

        string memory chainId = vm.toString(block.chainid);

        string memory deployments = readDeploymentFile();

        settlementDispatcherRain = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherRain"))
        );

        settlementDispatcherReap = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherReap"))
        );

        settlementDispatcherCardOrder = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherCardOrder"))
        );

        settlementDispatcherPix = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherPix"))
        );

        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

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

        settlementDispatcherRainImpl = address(new SettlementDispatcherV2(BinSponsor.Rain, dataProvider));
        settlementDispatcherReapImpl = address(new SettlementDispatcherV2(BinSponsor.Reap, dataProvider));
        settlementDispatcherCardOrderImpl = address(new SettlementDispatcherV2(BinSponsor.CardOrder, dataProvider));
        settlementDispatcherPixImpl = address(new SettlementDispatcherV2(BinSponsor.PIX, dataProvider));

        string memory txs = generateTransactions(chainId, tokens, destDatas);

        string memory path = string.concat("./output/UpgradeSettlementDispatcherEUR-", chainId, ".json");
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }

    function generateTransactions(string memory chainId, address[] memory tokens, SettlementDispatcherV2.DestinationData[] memory destDatas) internal view returns (string memory) {
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory upgradeRainTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherRainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherRain), upgradeRainTransaction, "0", false)));

        string memory upgradeReapTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherReapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), upgradeReapTransaction, "0", false)));

        string memory upgradeCardOrderTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherCardOrderImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherCardOrder), upgradeCardOrderTransaction, "0", false)));

        string memory upgradePixTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherPixImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherPix), upgradePixTransaction, "0", false)));

        string memory setDestinationDataRainTransaction = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setDestinationData.selector, tokens, destDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherRain), setDestinationDataRainTransaction, "0", false)));

        string memory setDestinationDataReapTransaction = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setDestinationData.selector, tokens, destDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), setDestinationDataReapTransaction, "0", false)));

        string memory setDestinationDataCardOrderTransaction = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setDestinationData.selector, tokens, destDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherCardOrder), setDestinationDataCardOrderTransaction, "0", false)));

        string memory setDestinationDataPixTransaction = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setDestinationData.selector, tokens, destDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherPix), setDestinationDataPixTransaction, "0", true)));

        return txs;
    }
}