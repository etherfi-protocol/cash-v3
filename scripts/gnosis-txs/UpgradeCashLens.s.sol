// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeCashLens is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        address cashLens = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashLens")
        );

        CashLens cashLensImpl = new CashLens(cashModule, dataProvider);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory cashLensUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, address(cashLensImpl), ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashLens), cashLensUpgrade, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeCashLens.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }
}