// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {StargateAdapter} from "../../../src/top-up/bridge/StargateAdapter.sol";

contract DeployStargateAdapter is Utils {
    StargateAdapter stargateAdapter;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory fixturesFile = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv() ,"/fixtures/top-up-fixtures.json"));
        string memory fixtures = vm.readFile(fixturesFile);
        string memory chainId = vm.toString(block.chainid);
        address weth = stdJson.readAddress(fixtures, string.concat(".", chainId, ".weth"));

        vm.startBroadcast(deployerPrivateKey);

        stargateAdapter = new StargateAdapter(weth);

        vm.stopBroadcast();
    }
}
