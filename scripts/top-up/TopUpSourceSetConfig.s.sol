// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpConfigHelper } from "../utils/TopUpConfigHelper.sol";

/// @title TopUpSourceSetConfig
/// @notice Reads token bridge configs from fixtures and sets them on the TopUpFactory (EOA broadcast).
///
/// Usage:
///   PRIVATE_KEY=0x... forge script scripts/top-up/TopUpSourceSetConfig.s.sol --rpc-url <RPC> --broadcast
contract TopUpSourceSetConfig is TopUpConfigHelper {

    function run() public virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readTopUpSourceDeployment();
        topUpFactory = TopUpFactory(payable(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory")));
        _loadAdapters(deployments);

        (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory configs) = parseAllTokenConfigs();

        vm.startBroadcast(deployerPrivateKey);
        topUpFactory.setTokenConfig(tokens, chainIds, configs);
        vm.stopBroadcast();

        console.log("Configured %s token+chain pairs", tokens.length);
    }
}
