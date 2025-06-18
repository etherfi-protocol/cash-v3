// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetDelays is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        string memory setDelays = iToHex(abi.encodeWithSelector(ICashModule.setDelays.selector, 10, 10, 10));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setDelays, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/SetDelays.json";
        vm.writeFile(path, txs);
        
        executeGnosisTransactionBundle(path);

    }
}