// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";

contract DeployTopUpSource is Utils {
    TopUpFactory topUpSourceFactory;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        bytes32 salt = keccak256("user1");
        topUpSourceFactory.deployTopUpContract(salt);

        vm.stopBroadcast();
    }
}
