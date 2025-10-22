// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {CCTPAdapter} from "../../../src/top-up/bridge/CCTPAdapter.sol";

contract DeployCCTPAdapter is Utils {
    CCTPAdapter cctpAdapter;

    function run(bool isDev) public {
        vm.startBroadcast();

        string memory saltName = isDev ? CCTP_ADAPTER_DEV : CCTP_ADAPTER;
        cctpAdapter = CCTPAdapter(deployWithCreate3(abi.encodePacked(type(CCTPAdapter).creationCode), getSalt(saltName)));

        vm.stopBroadcast();
    }
}

