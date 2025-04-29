// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SettlementDispatcherBridge is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        address settlementDispatcherReap = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));

        // uint256 balance = IERC20(usdc).balanceOf(settlementDispatcherReap);
        uint256 balance = 200_000e6;
        uint256 minAmount = 9998 * balance / 10000;
        ( , uint256 valueToSend, uint256 minReturnFromStargate, , ) = SettlementDispatcher(payable(settlementDispatcherReap)).prepareRideBus(usdc, balance); 
        
        if (minAmount > minReturnFromStargate) revert ("Stargate min return exceeds slippage");
        minAmount = minReturnFromStargate;

        string memory bridgeSettlementDispatcherReap = iToHex(abi.encodeWithSelector(SettlementDispatcher.bridge.selector, usdc, balance, minAmount));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), bridgeSettlementDispatcherReap, vm.toString(valueToSend), true)));

        vm.createDir("./output", true);
        string memory path = "./output/SettlementDispatcherReapBridge.json";
        vm.writeFile(path, txs);
        
        executeGnosisTransactionBundle(path);
    }
}