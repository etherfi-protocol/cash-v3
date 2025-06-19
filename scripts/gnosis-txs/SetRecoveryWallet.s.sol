// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetRecoveryWallet is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public { 
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();

        address topUpFactory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        string memory setRecoveryWallet = iToHex(abi.encodeWithSelector(TopUpFactory.setRecoveryWallet.selector, cashControllerSafe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), setRecoveryWallet, "0", false)));
        
        address usdbc = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
        uint256 amount = IERC20(usdbc).balanceOf(topUpFactory);

        string memory recoverFunds = iToHex(abi.encodeWithSelector(TopUpFactory.recoverFunds.selector, usdbc, amount));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), recoverFunds, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = string(abi.encodePacked("./output/SetRecoveryWallet-", chainId, ".json"));
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }    
}