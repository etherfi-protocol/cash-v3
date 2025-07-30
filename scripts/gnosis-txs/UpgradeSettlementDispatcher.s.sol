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



contract UpgradeSettlementDispatcher is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address constant settlementDispatcherReapImpl = 0xD7C422a48ecE1a5f883593d6d1CcB7A5dD486a3f;
    address constant settlementDispatcherRainImpl = 0x49859E57be078A0b9A396CBBf1B5197D13caEE92;

    address mainnetSettlementAddress = 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4;

    IERC20 public usdtScroll = IERC20(0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df);

    address public owner = 0x23ddE38BA34e378D28c667bC26b44310c7CA0997;

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

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe)); 

        string memory upgradeTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherReapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherReap)), upgradeTransaction, "0", false)));

        upgradeTransaction = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherRainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherRain)), upgradeTransaction, "0", false)));


        address[] memory tokens = new address[](1); 
        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);
        tokens[0] = address(usdtScroll);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: mainnetSettlementAddress,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 200_000
        });

        string memory setDestinationData = iToHex(abi.encodeWithSelector(SettlementDispatcher.setDestinationData.selector, tokens, destDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherReap)), setDestinationData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(settlementDispatcherRain)), setDestinationData, "0", true)));

        string memory path = string.concat("./output/UpgradeSettlementDispatchers-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);

        vm.startPrank(owner);

        deal(address(usdtScroll), address(settlementDispatcherRain), 1e6);
        SettlementDispatcher(payable(settlementDispatcherRain)).bridge(address(usdtScroll), 1e6, 1);
        assertEq(usdtScroll.balanceOf(address(settlementDispatcherRain)), 0);

        deal(address(usdtScroll), address(settlementDispatcherReap), 1e6);
        SettlementDispatcher(payable(settlementDispatcherReap)).bridge(address(usdtScroll), 1e6, 1);
        assertEq(usdtScroll.balanceOf(address(settlementDispatcherReap)), 0);
    }

}
