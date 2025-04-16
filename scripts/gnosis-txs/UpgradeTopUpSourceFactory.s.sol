// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeTopUpSourceFactory is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address topUpFactory;
    string chainId;
    string deployments;

    function run() public {
        deployments = readTopUpSourceDeployment();

        chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        topUpFactory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        );

        TopUpFactory topUpFactoryImpl = new TopUpFactory();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory upgradeTopUpSourceFactory = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(topUpFactoryImpl), ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), upgradeTopUpSourceFactory, true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/UpgradeTopUpSourceFactory-", chainId, ".json");
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);
    }
}