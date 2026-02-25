// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract FundsRecoveryArbitrum is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address USDCe = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();

        address topUpFactory = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "TopUpSourceFactory"));

        uint256 balanceUSDT0 = IERC20(USDT0).balanceOf(topUpFactory);
        uint256 balanceUSDCe = IERC20(USDCe).balanceOf(topUpFactory);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory recoverFundsUSDT0 = iToHex(abi.encodeWithSelector(TopUpFactory.recoverFunds.selector, USDT0, balanceUSDT0));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), recoverFundsUSDT0, "0", false)));

        string memory recoverFundsUSDCe = iToHex(abi.encodeWithSelector(TopUpFactory.recoverFunds.selector, USDCe, balanceUSDCe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), recoverFundsUSDCe, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/FundsRecoveryArbitrum-.json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}
