// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {NTTAdapter} from "../../../src/top-up/bridge/NTTAdapter.sol";

contract DeployNTTAdapter is Utils {
    NTTAdapter nttAdapter;

    function run() public {

        vm.startBroadcast();

        nttAdapter = NTTAdapter(deployWithCreate3(abi.encodePacked(type(NTTAdapter).creationCode), getSalt(NTT_ADAPTER)));

        vm.stopBroadcast();
    }
}
