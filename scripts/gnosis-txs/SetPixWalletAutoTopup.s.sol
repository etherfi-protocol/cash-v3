// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetPixWalletAutoTopup is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address pixSettlementDispatcher = 0xc5F2764383f93259Fba1D820b894B1DE0d47937e;
    address pixWalletAutoTopup = 0xf76f1bea29b5f63409a9d9797540A8E7934B52ea;
    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    function run() public {
        string memory chainId = vm.toString(block.chainid);

        SettlementDispatcher.DestinationData memory destinationData = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: pixWalletAutoTopup,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });

        address[] memory tokens = new address[](1);
        tokens[0] = usdc;

        SettlementDispatcher.DestinationData[] memory destinationDatas = new SettlementDispatcher.DestinationData[](1);
        destinationDatas[0] = destinationData;

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        string memory setPixWalletAutoTopup = iToHex(abi.encodeWithSelector(SettlementDispatcher.setDestinationData.selector, tokens, destinationDatas));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixSettlementDispatcher), setPixWalletAutoTopup, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/SetPixWalletAutoTopup.json";
        vm.writeFile(path, txs);
        
        executeGnosisTransactionBundle(path);
    }
}