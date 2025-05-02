// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { CashModuleSetters, SafeTiers } from "../../src/modules/cash/CashModuleSetters.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetTierCashbackPercentage is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));

        SafeTiers[] memory tiers = new SafeTiers[](5);
        tiers[0] = SafeTiers.Pepe;
        tiers[1] = SafeTiers.Wojak;
        tiers[2] = SafeTiers.Chad;
        tiers[3] = SafeTiers.Whale;
        tiers[4] = SafeTiers.Business;

        uint256[] memory cashbackPercentages = new uint256[](5);
        cashbackPercentages[0] = 200;
        cashbackPercentages[1] = 300;
        cashbackPercentages[2] = 300;
        cashbackPercentages[3] = 400;
        cashbackPercentages[4] = 200;

        string memory setCashbackTiers = iToHex(abi.encodeWithSelector(CashModuleSetters.setTierCashbackPercentage.selector, tiers, cashbackPercentages));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setCashbackTiers, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/SetTierCashbackPercentage.json";
        vm.writeFile(path, txs);
        
        executeGnosisTransactionBundle(path);
    }
}