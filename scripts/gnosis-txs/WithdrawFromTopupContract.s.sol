// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract WithdrawFromTopupContract is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address topUpDest = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;

    address public weEth = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    uint256 amount = 100 ether;

    function run() public {
        string memory chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory withdrawFromTopUpDest = iToHex(abi.encodeWithSelector(TopUpDest.withdraw.selector, weEth, amount));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(topUpDest), withdrawFromTopUpDest, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/WithdrawFromTopupContract.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }
}