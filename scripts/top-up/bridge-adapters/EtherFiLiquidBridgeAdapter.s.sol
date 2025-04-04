// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../../utils/Utils.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {EtherFiLiquidBridgeAdapter} from "../../../src/top-up/bridge/EtherFiLiquidBridgeAdapter.sol";

contract DeployEtherFiLiquidBridgeAdapter is Utils {
    EtherFiLiquidBridgeAdapter liquidBridgeAdapter;

    function run() public {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast();

        liquidBridgeAdapter = EtherFiLiquidBridgeAdapter(deployWithCreate3(abi.encodePacked(type(EtherFiLiquidBridgeAdapter).creationCode), getSalt(ETHER_FI_LIQUID_BRIDGE_ADAPTER)));

        vm.stopBroadcast();
    }
}