// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { RampVolumeEmitter } from "../src/ramp-volume/RampVolumeEmitter.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { Utils, ChainConfig } from "./utils/Utils.sol";

/**
 * @notice Deploys RampVolumeEmitter behind a UUPS proxy and grants the backend relayer
 *         RAMP_VOLUME_EMITTER_ROLE.
 * @dev grantRole must be sent by the RoleRegistry owner. On networks where the owner is a
 *      multisig/governance (prod), drop the grantRole line and grant via scripts/gnosis-txs/.
 *      Env: PRIVATE_KEY (deployer), RAMP_VOLUME_RELAYER (relayer to authorize), plus ENV +
 *      chain so readDeploymentFile() resolves the RoleRegistry address.
 */
contract DeployRampVolumeEmitter is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address relayer = vm.envAddress("RAMP_VOLUME_RELAYER");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));

        vm.startBroadcast(deployerPrivateKey);

        bytes memory initData = abi.encodeWithSelector(RampVolumeEmitter.initialize.selector, roleRegistry);
        address impl = address(new RampVolumeEmitter());
        address proxy = address(new UUPSProxy(impl, initData));

        RoleRegistry(roleRegistry).grantRole(RampVolumeEmitter(proxy).RAMP_VOLUME_EMITTER_ROLE(), relayer);

        vm.stopBroadcast();

        console2.log("RampVolumeEmitter impl :", impl);
        console2.log("RampVolumeEmitter proxy:", proxy);
        console2.log("Relayer granted RAMP_VOLUME_EMITTER_ROLE:", relayer);
    }
}
