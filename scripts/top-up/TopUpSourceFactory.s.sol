// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {TopUp} from "../../src/top-up/TopUp.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";

contract DeployTopUpSourceFactory is Utils {
    TopUpFactory factory;
    RoleRegistry roleRegistry; 

    function run() public {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address owner = 0x8D5AAc5d3d5cda4c404fA7ee31B0822B648Bb150;

        vm.startBroadcast();
        string memory deployments = readTopUpSourceDeployment();

        roleRegistry = RoleRegistry(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        ));

        address factoryImpl = deployWithCreate3(abi.encodePacked(type(TopUpFactory).creationCode, ""), getSalt(TOP_UP_SOURCE_FACTORY_IMPL));
        address topUpImpl = deployWithCreate3(abi.encodePacked(type(TopUp).creationCode, ""), getSalt(TOP_UP_SOURCE_IMPL));
        address topUpFactoryProxy = deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(factoryImpl, "")), getSalt(TOP_UP_SOURCE_FACTORY_PROXY));
        factory = TopUpFactory(payable(topUpFactoryProxy));

        factory.initialize(address(roleRegistry), topUpImpl);
        roleRegistry.grantRole(factory.TOPUP_FACTORY_ADMIN_ROLE(), owner);

        vm.stopBroadcast();
    }
}
