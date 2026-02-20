// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract USDCeFundsRecovery is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address USDCe = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();

        address topUpFactory = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "TopUpSourceFactory"));

        uint256 balance = IERC20(USDCe).balanceOf(topUpFactory);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory recoverFunds = iToHex(abi.encodeWithSelector(TopUpFactory.recoverFunds.selector, USDCe, balance));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), recoverFunds, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/FundsRecovery-", chainId, "-USDCe.json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}
