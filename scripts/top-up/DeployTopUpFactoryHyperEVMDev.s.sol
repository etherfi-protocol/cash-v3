// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSProxy} from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {TopUp} from "../../src/top-up/TopUp.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";

/**
 * @title DeployTopUpFactoryHyperEVMDev
 * @notice Deploys the dev TopUp factory stack to HyperEVM using standard deployments
 * @dev Mirrors the production deployment script but without deterministic CREATE3 usages
 */
contract DeployTopUpFactoryHyperEVMDev is Utils {
    TopUpFactory factory;
    RoleRegistry roleRegistry;

    // HyperEVM WETH address (dev)
    address constant HYPEREVM_WETH = 0x5555555555555555555555555555555555555555;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        address roleRegistryImpl = address(new RoleRegistry(address(0)));

        bytes memory roleRegistryInitData = abi.encodeWithSelector(
            RoleRegistry.initialize.selector,
            deployer
        );

        roleRegistry = RoleRegistry(
            address(new UUPSProxy(roleRegistryImpl, roleRegistryInitData))
        );

        address factoryImpl = address(new TopUpFactory());
        address topUpImpl = address(new TopUp(HYPEREVM_WETH));

        bytes memory factoryInitData = abi.encodeWithSelector(
            TopUpFactory.initialize.selector,
            address(roleRegistry),
            topUpImpl
        );

        address topUpFactoryProxy = address(new UUPSProxy(factoryImpl, factoryInitData));

        factory = TopUpFactory(payable(topUpFactoryProxy));

        vm.stopBroadcast();
    }
}


