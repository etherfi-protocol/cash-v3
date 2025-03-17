// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {EtherFiOFTBridgeAdapter} from "../../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";

contract DeployOFTBridgeAdapter is Utils {
    EtherFiOFTBridgeAdapter etherFiOFTBridgeAdapter;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        etherFiOFTBridgeAdapter = deployWithCreate3(abi.encodePacked(type(EtherFiOFTBridgeAdapter).creationCode), getSalt(ETHER_FI_OFT_BRIDGE_ADAPTER));

        vm.stopBroadcast();
    }
}