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

        address roleRegistryImpl = deployWithCreate3(abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))), getSalt(ROLE_REGISTRY_IMPL));
        roleRegistry = RoleRegistry(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(roleRegistryImpl, "")), getSalt(ROLE_REGISTRY_PROXY)));

        roleRegistry.initialize(owner);
        vm.stopBroadcast();
    }
}