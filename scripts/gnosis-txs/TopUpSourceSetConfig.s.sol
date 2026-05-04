// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpConfigHelper } from "../utils/TopUpConfigHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/// @title TopUpSourceSetConfig (Gnosis)
/// @notice Generates a Gnosis Safe batch to configure TopUpFactory token bridges.
///
/// Usage:
///   forge script scripts/gnosis-txs/TopUpSourceSetConfig.s.sol --rpc-url <RPC> --broadcast
contract TopUpSourceSetConfig is TopUpConfigHelper, GnosisHelpers {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        string memory deployments = readTopUpSourceDeployment();
        string memory chainId = vm.toString(block.chainid);

        topUpFactory = TopUpFactory(payable(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory")));
        _loadAdapters(deployments);

        (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory configs) = parseAllTokenConfigs();

        // Generate gnosis tx
        vm.startBroadcast();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        string memory setTokenConfig = iToHex(abi.encodeWithSelector(
            TopUpFactory.setTokenConfig.selector, tokens, chainIds, configs
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(address(topUpFactory)), setTokenConfig, "0", true
        )));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/TopUpSetConfig-", chainId, ".json");
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        console.log("Generated gnosis tx with %s token+chain configs", tokens.length);

        // Simulate
        executeGnosisTransactionBundle(path);
    }
}
