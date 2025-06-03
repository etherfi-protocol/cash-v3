// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract TransferUsdcFromSDToRefund is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address refundAddress = 0xF6B3422e3CC70fa9fce4fAb9A706ED2497c7bb9e;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        address settlementDispatcherReap = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));

        string memory transferSettlementDispatcherReap = iToHex(abi.encodeWithSelector(SettlementDispatcher.withdrawFunds.selector, usdc, refundAddress, 50000e6));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), transferSettlementDispatcherReap, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/TransferUsdcFromSDToRefund.json";
        vm.writeFile(path, txs);
        
        executeGnosisTransactionBundle(path);
    }
}