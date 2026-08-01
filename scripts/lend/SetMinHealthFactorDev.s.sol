// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title SetMinHealthFactorDev
 * @notice Raises the dev LendGateway's minimum health factor from the deploy-time 1.05 to 1.10,
 *         the day-one value proposed for the prod gateway, so dev rehearses the prod guardrail.
 * @dev Dev-only. The CLI sender must hold LEND_GATEWAY_ADMIN_ROLE (the dev admin from
 *      DeployCashLendDev). Idempotent.
 *
 * Usage (drop --broadcast for simulation):
 *   source .env && ENV=dev forge script \
 *     scripts/lend/SetMinHealthFactorDev.s.sol:SetMinHealthFactorDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract SetMinHealthFactorDev is Utils {
    uint256 constant MIN_HEALTH_FACTOR = 1.1e18;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        string memory record = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json"));
        LendGateway gateway = LendGateway(stdJson.readAddress(record, ".lendGateway"));

        string memory deployments = readDeploymentFile();
        RoleRegistry registry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(registry.hasRole(gateway.LEND_GATEWAY_ADMIN_ROLE(), deployer), "sender missing LendGateway admin role");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        gateway.setMinHealthFactor(MIN_HEALTH_FACTOR);
        vm.stopBroadcast();

        require(gateway.minHealthFactor() == MIN_HEALTH_FACTOR, "minHealthFactor not applied");
        console.log("dev LendGateway minHealthFactor set to", MIN_HEALTH_FACTOR);
    }
}
