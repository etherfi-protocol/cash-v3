// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract AddFunds is GnosisHelpers, Utils {
    address safe = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;

    address public weEth = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        address debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        address topUpDest = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpDest")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));

        string memory approveSupplyUsdcToDebtManager = iToHex(abi.encodeWithSelector(IERC20.approve.selector, debtManager, 500e6));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(usdc), approveSupplyUsdcToDebtManager, "0", false)));

        string memory supplyUsdcToDebtManager = iToHex(abi.encodeWithSelector(IDebtManager.supply.selector, safe, usdc, 500e6));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), supplyUsdcToDebtManager, "0", false)));
        
        string memory approveSupplyUsdcToTopUpDest = iToHex(abi.encodeWithSelector(IERC20.approve.selector, topUpDest, 500e6));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(usdc), approveSupplyUsdcToTopUpDest, "0", false)));
        
        string memory supplyUsdcToTopUpDest = iToHex(abi.encodeWithSelector(TopUpDest.deposit.selector, usdc, 500e6));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(topUpDest), supplyUsdcToTopUpDest, "0", false)));
        
        string memory approveSupplyWeEthToTopUpDest = iToHex(abi.encodeWithSelector(IERC20.approve.selector, topUpDest, 1 ether));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(weEth), approveSupplyWeEthToTopUpDest, "0", false)));

        string memory supplyWeEthToTopUpDest = iToHex(abi.encodeWithSelector(TopUpDest.deposit.selector, weEth, 1 ether));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(topUpDest), supplyWeEthToTopUpDest, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/AddFunds.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}