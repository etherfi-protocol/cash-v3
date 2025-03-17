// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {StargateAdapter} from "../../../src/top-up/bridge/StargateAdapter.sol";

contract DeployStargateAdapter is Utils {
    StargateAdapter stargateAdapter;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        stargateAdapter = deployWithCreate3(abi.encodePacked(type(StargateAdapter).creationCode), getSalt(STARGATE_ADAPTER));

        vm.stopBroadcast();
    }
}
