// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {BaseWithdrawERC20BridgeAdapter} from "../../../src/top-up/bridge/BaseWithdrawERC20BridgeAdapter.sol";

contract DeployBaseWithdrawERC20BridgeAdapter is Utils {
    BaseWithdrawERC20BridgeAdapter baseWithdrawERC20BridgeAdapter;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        baseWithdrawERC20BridgeAdapter = BaseWithdrawERC20BridgeAdapter(deployWithCreate3(abi.encodePacked(type(BaseWithdrawERC20BridgeAdapter).creationCode), getSalt(BASE_WITHDRAW_ERC20_BRIDGE_ADAPTER)));

        vm.stopBroadcast();
    }
}
