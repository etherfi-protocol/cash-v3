// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IOFTConfigRegistry } from "../src/interfaces/IOFTConfigRegistry.sol";
import { ConfigurableOFTBase } from "../src/oft/ConfigurableOFTBase.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title PauseOFTBridges
 * @author ether.fi
 * @notice "Pause everything" (COR-923): the on-chain control is per-bridge {ConfigurableOFTBase-pauseBridge}
 *         gated by the RoleRegistry PAUSER role, so the global switch is a Safe BATCH of those calls —
 *         the same pattern weETH-cross-chain uses. This script enumerates every registered bridge from
 *         the {OFTConfigRegistry} and either broadcasts the pause (if the caller holds PAUSER) or logs the
 *         per-bridge calldata to submit from the PAUSER Safe.
 * @dev Set OFT_UNPAUSE=true to emit the inverse (unpause) batch — note unpause is gated to UNPAUSER.
 *      Run once per chain:
 *        PRIVATE_KEY=<pauser> forge script scripts/PauseOFTBridges.s.sol --rpc-url <mainnet|optimism> --broadcast
 */
contract PauseOFTBridges is Utils {
    function run() public {
        bool unpause = vm.envOr("OFT_UNPAUSE", false);
        bool broadcast = vm.envOr("OFT_BROADCAST", false);

        string memory deployments = readDeploymentFile();
        IOFTConfigRegistry registry = IOFTConfigRegistry(stdJson.readAddress(deployments, ".addresses.OFTConfigRegistry"));

        uint256 n = registry.numBridges();
        address[] memory bridges = registry.getBridges(0, n);
        bytes memory data = unpause ? abi.encodeWithSelector(ConfigurableOFTBase.unpauseBridge.selector) : abi.encodeWithSelector(ConfigurableOFTBase.pauseBridge.selector);

        console.log(unpause ? "UNPAUSE" : "PAUSE", "all OFT bridges on chainId", block.chainid);
        console.log("  registry:", address(registry));
        console.log("  bridges: ", n);

        if (broadcast) {
            uint256 pk = vm.envUint("PRIVATE_KEY");
            for (uint256 i; i < n; ++i) {
                vm.broadcast(pk);
                (bool ok,) = bridges[i].call(data);
                require(ok, "pause call failed (caller lacks PAUSER/UNPAUSER?)");
                console.log("  toggled", bridges[i]);
            }
        } else {
            // Log the batch to submit from the PAUSER/UNPAUSER Safe (one tx per bridge, same calldata).
            console.log("  submit this calldata to each target FROM the role-holder Safe:");
            console.logBytes(data);
            for (uint256 i; i < n; ++i) {
                console.log("    target:", bridges[i]);
            }
        }
    }
}
