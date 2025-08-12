// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SettlementDispatcher, BinSponsor} from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract DeploySettlementDispatcher is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory dir = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv(), "/"));
        string memory chainDir = string.concat(scrollChainId, "/");
        string memory file = string.concat(dir, chainDir, "deployments", ".json");
        string memory scrollDeployments = vm.readFile(file);
        address etherFiDataProvider = stdJson.readAddress(
            scrollDeployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        // Reap settlement dispatcher
        address settlementDispatcherReap = address(new SettlementDispatcher(BinSponsor(0), etherFiDataProvider));
        // Rain settlement dispatcher
        address settlementDispatcherRain = address(new SettlementDispatcher(BinSponsor(1), etherFiDataProvider));

        vm.stopBroadcast();
    }

}
