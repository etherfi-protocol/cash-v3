// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {TopUp} from "../../src/top-up/TopUp.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";

/**TopUpSourceFactory
 * @title DeployTopUpFactoryHyperEVM
 * @notice Deploys the complete TopUp factory infrastructure on HyperEVM using CREATE3
 * @dev This script deploys RoleRegistry and TopUpFactory with deterministic addresses
 *      matching deployments on Mainnet and Base
 */
contract DeployTopUpFactoryHyperEVM is Utils {
    TopUpFactory factory;
    RoleRegistry roleRegistry;
    
    // HyperEVM WETH address
    address constant HYPEREVM_WETH = 0x5555555555555555555555555555555555555555;
    
    // Base and Mainnet TopUpFactory addresses
    address constant EXPECTED_TOP_UP_FACTORY = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        address roleRegistryImpl = deployWithCreate3(
            abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))), 
            getSalt(ROLE_REGISTRY_IMPL)
        );
        
        bytes memory roleRegistryInitData = abi.encodeWithSelector(
            RoleRegistry.initialize.selector,
            deployer
        );
        
        roleRegistry = RoleRegistry(
            deployWithCreate3(
                abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(roleRegistryImpl, roleRegistryInitData)), 
                getSalt(ROLE_REGISTRY_PROXY)
            )
        );

        address factoryImpl = deployWithCreate3(
            abi.encodePacked(type(TopUpFactory).creationCode, ""), 
            getSalt(TOP_UP_SOURCE_FACTORY_IMPL)
        );
        
        address topUpImpl = deployWithCreate3(
            abi.encodePacked(type(TopUp).creationCode, abi.encode(HYPEREVM_WETH)), 
            getSalt(TOP_UP_SOURCE_IMPL)
        );
        
        bytes memory factoryInitData = abi.encodeWithSelector(
            TopUpFactory.initialize.selector,
            address(roleRegistry),
            topUpImpl
        );
        
        address topUpFactoryProxy = deployWithCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(factoryImpl, factoryInitData)), 
            getSalt(TOP_UP_SOURCE_FACTORY_PROXY)
        );

        factory = TopUpFactory(payable(topUpFactoryProxy));

        require(
            address(factory) == EXPECTED_TOP_UP_FACTORY,
            "TopUpFactory address mismatch"
        );

        vm.stopBroadcast();
    }
}

