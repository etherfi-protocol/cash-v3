// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract eETHFundsRecovery is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();

        address topUpFactory = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "TopUpSourceFactory"));

        uint256 balance = IERC20(eETH).balanceOf(topUpFactory);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory recoverFunds = iToHex(abi.encodeWithSelector(TopUpFactory.recoverFunds.selector, eETH, balance));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), recoverFunds, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/FundsRecovery-", chainId, "-eETH.json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}
