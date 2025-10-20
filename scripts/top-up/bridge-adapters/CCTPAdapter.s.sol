// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {CCTPAdapter} from "../../../src/top-up/bridge/CCTPAdapter.sol";

contract DeployCCTPAdapter is Utils {
    CCTPAdapter cctpAdapter;

    function run() public {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast();

        cctpAdapter = CCTPAdapter(deployWithCreate3(abi.encodePacked(type(CCTPAdapter).creationCode), getSalt(CCTP_ADAPTER)));

        vm.stopBroadcast();
    }
}

