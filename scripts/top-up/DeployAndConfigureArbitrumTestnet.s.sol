// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Console.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {TopUp} from "../../src/top-up/TopUp.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";
import {CCTPAdapter} from "../../src/top-up/bridge/CCTPAdapter.sol";

/**
 * @title DeployAndConfigureArbitrumTestnet
 * @notice Full deployment and configuration script for Arbitrum testnet
 * @dev Deploys RoleRegistry, TopUpFactory, CCTPAdapter and configures USDC with CCTP
 */
contract DeployAndConfigureArbitrumTestnet is Utils {
    RoleRegistry public roleRegistry;
    TopUpFactory public topUpFactory;
    CCTPAdapter public cctpAdapter;
    
    address constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CCTP_TOKEN_MESSENGER = 0x19330d10D9Cc8751218eaf51E8885D058642E08A;
    
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
                getSalt(ROLE_REGISTRY_PROXY_DEV)
            )
        );

        address factoryImpl = deployWithCreate3(
            abi.encodePacked(type(TopUpFactory).creationCode, ""), 
            getSalt(TOP_UP_SOURCE_FACTORY_IMPL_DEV)
        );
        
        address topUpImpl = deployWithCreate3(
            abi.encodePacked(type(TopUp).creationCode, abi.encode(ARBITRUM_WETH)), 
            getSalt(TOP_UP_SOURCE_IMPL_DEV)
        );
        
        bytes memory factoryInitData = abi.encodeWithSelector(
            TopUpFactory.initialize.selector,
            address(roleRegistry),
            topUpImpl
        );
        
        address topUpFactoryProxy = deployWithCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(factoryImpl, factoryInitData)), 
            getSalt(TOP_UP_SOURCE_FACTORY_PROXY_DEV)
        );

        topUpFactory = TopUpFactory(payable(topUpFactoryProxy));

        cctpAdapter = CCTPAdapter(
            deployWithCreate3(
                abi.encodePacked(type(CCTPAdapter).creationCode), 
                getSalt(CCTP_ADAPTER_DEV)
            )
        );

        address[] memory tokens = new address[](1);
        TopUpFactory.TokenConfig[] memory tokenConfig = new TopUpFactory.TokenConfig[](1);

        tokens[0] = ARBITRUM_USDC;
        tokenConfig[0].recipientOnDestChain = address(topUpFactory); 
        tokenConfig[0].maxSlippageInBps = 0; 
        tokenConfig[0].bridgeAdapter = address(cctpAdapter);
        tokenConfig[0].additionalData = abi.encode(CCTP_TOKEN_MESSENGER, uint256(0), uint32(2000));

        topUpFactory.setTokenConfig(tokens, tokenConfig);
        
        vm.stopBroadcast();
    }
}

