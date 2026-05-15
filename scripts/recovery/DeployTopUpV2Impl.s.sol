// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { BeaconFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig } from "./RecoveryDeployConfig.sol";

/**
 * @notice Deploys `TopUpV2` impl on one destination chain and prints the
 *         `BeaconFactory.upgradeBeaconImplementation` calldata for the 3CP.
 *
 * Env:
 *   RECOVERY_DISPATCHER    — AssetRecoveryDispatcher proxy on this chain
 *   WETH                   — WETH address on this chain
 */
contract DeployTopUpV2Impl is Utils {
    function run() external {
        address dispatcher = vm.envAddress("RECOVERY_DISPATCHER");
        address weth = vm.envAddress("WETH");
        require(weth != address(0), "WETH cannot be zero address");
        require(weth.code.length > 0, "WETH has no code on this chain");

        string memory deployments = readTopUpSourceDeployment();
        address beaconFactory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        );
        require(beaconFactory != address(0), "TopUpSourceFactory not found in deployments.json");

        vm.startBroadcast();

        TopUpV2 impl = new TopUpV2(weth, dispatcher);

        vm.stopBroadcast();

        // --- Post-deploy verification: read back immutables ---
        require(impl.DISPATCHER() == dispatcher, "VERIFY FAILED: DISPATCHER mismatch");

        bytes memory upgradeCalldata = abi.encodeCall(
            BeaconFactory.upgradeBeaconImplementation,
            (address(impl))
        );

        bytes32 codeHash = keccak256(address(impl).code);

        console.log("chainId          : %s", block.chainid);
        console.log("weth             : %s", weth);
        console.log("dispatcher       : %s", dispatcher);
        console.log("beacon factory   : %s", beaconFactory);
        console.log("TopUpV2 impl     : %s", address(impl));
        console.log("Runtime bytecode hash:");
        console.logBytes32(codeHash);
        console.log("");
        console.log("3CP calldata - operating safe signs on this chain:");
        console.log("  target  : %s (BeaconFactory)", beaconFactory);
        console.log("  method  : upgradeBeaconImplementation(%s)", address(impl));
        console.log("  calldata:");
        console.logBytes(upgradeCalldata);
    }
}
