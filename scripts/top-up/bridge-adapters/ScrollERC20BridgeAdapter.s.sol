// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {ScrollERC20BridgeAdapter} from "../../../src/top-up/bridge/ScrollERC20BridgeAdapter.sol";

contract DeployScrollERC20BridgeAdapter is Utils {
    ScrollERC20BridgeAdapter scrollERC20BridgeAdapter;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        scrollERC20BridgeAdapter = ScrollERC20BridgeAdapter(deployWithCreate3(abi.encodePacked(type(ScrollERC20BridgeAdapter).creationCode), getSalt(SCROLL_ERC20_BRIDGE_ADAPTER_DEV)));

        vm.stopBroadcast();
    }
}
