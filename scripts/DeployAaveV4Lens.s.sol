// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { AaveV4Lens } from "../src/lens/AaveV4Lens.sol";
import { UUPSProxy } from "../src/UUPSProxy.sol";
import { Utils } from "./utils/Utils.sol";

/// @title DeployAaveV4Lens
/// @notice Deploys the AaveV4Lens read aggregator on Optimism behind the standard ether.fi UUPS
///         proxy (upgrades gated by the environment's RoleRegistry, read from deployments.json).
///         The lens takes the spoke as a call argument, so one deployment serves the test
///         instance and the official market.
///
/// Usage:
///   source .env && ENV=dev forge script scripts/DeployAaveV4Lens.s.sol:DeployAaveV4Lens --rpc-url $OPTIMISM_RPC --broadcast -vvvv
contract DeployAaveV4Lens is Utils {
    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        address roleRegistry = stdJson.readAddress(readDeploymentFile(), ".addresses.RoleRegistry");
        console.log("RoleRegistry:", roleRegistry);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address lensImpl = address(new AaveV4Lens());
        AaveV4Lens lens = AaveV4Lens(address(new UUPSProxy(lensImpl, abi.encodeWithSelector(AaveV4Lens.initialize.selector, roleRegistry))));
        vm.stopBroadcast();

        console.log("AaveV4Lens impl: ", lensImpl);
        console.log("AaveV4Lens proxy:", address(lens));
    }
}
