// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { Utils, ChainConfig } from "../utils/Utils.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract DeployRoleRegistry is Utils {
    RoleRegistry roleRegistry; 

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        ChainConfig chainConfig = getChainConfig(block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        address roleRegistryImpl = address(new RoleRegistry(address(0)));
        roleRegistry = RoleRegistry(address(new UUPSProxy(
            roleRegistryImpl, 
            abi.encodeWithSelector(RoleRegistry.initialize.selector, chainConfig.owner)
        )));

        vm.stopBroadcast();
    }
}