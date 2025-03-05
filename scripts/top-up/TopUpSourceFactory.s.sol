// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";

contract DeployTopUpSourceFactory is Utils {
    TopUpFactory factory;
    RoleRegistry roleRegistry; 

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        roleRegistry = RoleRegistry(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        ));

        ChainConfig chainConfig = getChainConfig(block.chainid);

        address factoryImpl = address(new TopUpFactory{salt: getSalt(TOP_UP_SOURCE_FACTORY_IMPL)}());
        factory = TopUpFactory(payable(address(new UUPSProxy{salt: getSalt(TOP_UP_SOURCE_FACTORY_PROXY)}(
            factoryImpl, 
            abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), implementation)
        ))));
        roleRegistry.grantRole(factory.TOPUP_FACTORY_ADMIN_ROLE(), chainConfig.owner);

        vm.stopBroadcast();
    }
}
