// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { Utils, ChainConfig } from "../utils/Utils.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

contract DeployRoleRegistry is Utils {
    RoleRegistry roleRegistry; 

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address owner = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

        vm.startBroadcast(deployerPrivateKey);

        address roleRegistryImpl = address(new RoleRegistry{salt: getSalt(ROLE_REGISTRY_IMPL)}(address(0)));
        roleRegistry = RoleRegistry(address(new UUPSProxy{salt: getSalt(ROLE_REGISTRY_PROXY)}(
            roleRegistryImpl, 
            ""
        )));

        roleRegistry.initialize(owner);
        vm.stopBroadcast();
    }
}