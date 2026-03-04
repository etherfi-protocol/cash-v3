// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

import {Utils} from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

contract UpdateSettlementAddress is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public usdtScroll = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address public usdcScroll = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    address public roleRegistry = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;

    address mainnetSettlementAddress = 0xEf92B8aF3C92Dc87D1526eFB195c514608De15B5;
    address settlementDispatcherReap;
    address settlementDispatcherRain;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        settlementDispatcherReap = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        );
        settlementDispatcherRain = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherRain")
        );

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

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory updateSettlementAddress = iToHex(abi.encodeWithSelector(SettlementDispatcher.setDestinationData.selector, SettlementDispatcherTokens, destDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), updateSettlementAddress, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherRain), updateSettlementAddress, "0", true)));

        string memory path = string.concat("./output/UpdateSettlementAddress.json");
        vm.writeFile(path, txs);
        executeGnosisTransactionBundle(path);

        test();
    }

    function test() public {
        vm.startPrank(cashControllerSafe);

        RoleRegistry(roleRegistry).grantRole(SettlementDispatcher(payable(settlementDispatcherReap)).SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), cashControllerSafe);

        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.CanonicalBridgeWithdraw(usdcScroll, mainnetSettlementAddress, 10e6);
        SettlementDispatcher(payable(settlementDispatcherReap)).bridge(usdcScroll, 10e6, 10e6);

        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.CanonicalBridgeWithdraw(usdtScroll, mainnetSettlementAddress, 10e6);
        SettlementDispatcher(payable(settlementDispatcherReap)).bridge(usdtScroll, 10e6, 10e6);

        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.CanonicalBridgeWithdraw(usdcScroll, mainnetSettlementAddress, 10e6);
        SettlementDispatcher(payable(settlementDispatcherRain)).bridge(usdcScroll, 10e6, 10e6);

        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.CanonicalBridgeWithdraw(usdtScroll, mainnetSettlementAddress, 10e6);
        SettlementDispatcher(payable(settlementDispatcherRain)).bridge(usdtScroll, 10e6, 10e6);

        vm.stopPrank();
    }
}