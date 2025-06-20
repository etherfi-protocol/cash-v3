// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetInterestRate is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    uint64 oneYear = 365 * 24 * 3600;
    uint64 interestRate = 4e18 / oneYear;
    
    address debtManager;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory setInterestRate = iToHex(abi.encodeWithSelector(IDebtManager.setBorrowApy.selector, usdc, interestRate));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setInterestRate, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = "./output/SetInterestRate.json";
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);

    }
}