// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { LiquidUSDLiquifierModule } from "../../src/modules/etherfi/LiquidUSDLiquifier.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract AddLiquidUSDLiquifierModule is GnosisHelpers, Utils, Test {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        address liquidUSDLiquifierModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "LiquidUSDLiquifierModule")
        );

        address etherFiDataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        address[] memory modules = new address[](1);
        modules[0] = liquidUSDLiquifierModule;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));

        string memory configureDefaultModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(etherFiDataProvider), configureDefaultModules, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/AddLiquidUSDLiquifierModule.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}