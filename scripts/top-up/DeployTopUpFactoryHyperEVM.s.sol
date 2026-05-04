// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {TopUp} from "../../src/top-up/TopUp.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";

contract DeployTopUpSourceFactory is Utils {
    TopUpFactory factory;
    RoleRegistry roleRegistry; 

    address whype = 0x5555555555555555555555555555555555555555;

    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SALT_SAFE_FACTORY_PROXY_DEV          = 0xf8a17770967b5e97224007959b54d404185c01430bf45f1048077170756cf305;
    bytes32 constant SALT_SAFE_IMPL_DEV                   = 0x46c5c6bcff9d7a0c52cab6e0c76f094300cb0d93a9ee3b69b5f18d2f51217458;
    bytes32 constant SALT_SAFE_FACTORY_IMPL_DEV           = 0xc8e64830043c6ed113c4b9f1ff41f8a859a0a99b497a8ea4468021dc5ddf717f;

    bytes32 constant SALT_SAFE_IMPL_PROD                   = 0xff29656f33cc018695c4dadfbd883155f1ef30d667ca50827a9b9c56a50fe803;
    bytes32 constant SALT_SAFE_FACTORY_IMPL_PROD           = 0x89a0cb186faf1ec3240a4a2bdefe0124bd4fac7547ef1d07ad0d1f1a9f30cafe; 
    bytes32 constant SALT_SAFE_FACTORY_PROXY_PROD          = 0x4039d84c2c2b96cb1babbf2ca5c0b7be213be8ad0110e70d6e2d570741ef168b; 

    bytes32 SALT_SAFE_IMPL;
    bytes32 SALT_SAFE_FACTORY_IMPL;
    bytes32 SALT_SAFE_FACTORY_PROXY;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        if (getEnv() == "dev") {
            SALT_SAFE_IMPL = SALT_SAFE_IMPL_DEV;
            SALT_SAFE_FACTORY_IMPL = SALT_SAFE_FACTORY_IMPL_DEV;
            SALT_SAFE_FACTORY_PROXY = SALT_SAFE_FACTORY_PROXY_DEV;
        } else {
            SALT_SAFE_IMPL = SALT_SAFE_IMPL_PROD;
            SALT_SAFE_FACTORY_IMPL = SALT_SAFE_FACTORY_IMPL_PROD;
            SALT_SAFE_FACTORY_PROXY = SALT_SAFE_FACTORY_PROXY_PROD;
        }

        vm.startBroadcast(deployerPrivateKey);
        string memory deployments = readTopUpSourceDeployment();

        roleRegistry = RoleRegistry(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        ));

        address factoryImpl = deployCreate3(abi.encodePacked(type(TopUpFactory).creationCode), SALT_SAFE_FACTORY_IMPL);
        address topUpImpl = deployCreate3(abi.encodePacked(type(TopUp).creationCode, abi.encode(whype)), SALT_SAFE_IMPL);

        bytes memory factoryInitData = abi.encodeWithSelector(
            TopUpFactory.initialize.selector,
            address(roleRegistry),
            topUpImpl
        );

        address topUpFactoryProxy = deployCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(factoryImpl, factoryInitData)), SALT_SAFE_FACTORY_PROXY);
        factory = TopUpFactory(payable(topUpFactoryProxy));

        vm.stopBroadcast();
    }

    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }
}
