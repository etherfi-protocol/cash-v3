// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { BeaconFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @notice Deploys `TopUpV2` impl on one destination chain via Nick's CREATE3 factory
 *         (so each chain lands at the same address) and prints the
 *         `BeaconFactory.upgradeBeaconImplementation` calldata that the operating safe
 *         will 3CP-sign.
 *
 * Env:
 *   PRIVATE_KEY        — deployer key
 *   TOPUP_DISPATCHER   — TopUpDispatcher proxy on this chain (from DeployTopUpDispatcher)
 *
 * Reads beacon factory + WETH from the repo's deployment JSONs
 * (`deployments/<env>/<chainId>/deployments.json` + `fixtures.json`).
 */
contract UpgradeTopUpImpl is Utils, RecoveryDeployHelper {
    function run() external {
        require(RecoveryDeployConfig.NICKS_FACTORY.code.length > 0, "Nick's factory not on this chain");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address dispatcher = vm.envAddress("TOPUP_DISPATCHER");

        ChainConfig memory cfg = getChainConfig(vm.toString(block.chainid));
        address weth = cfg.weth;
        require(weth != address(0), "weth not configured for this chain");

        string memory deployments = readTopUpSourceDeployment();
        address beaconFactory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        );
        require(beaconFactory != address(0), "TopUpSourceFactory not found in deployments.json");

        // TopUpV2 impl salt is parameterized by (weth, dispatcher) — different chains have
        // different weth/dispatcher, so impl addresses will differ across chains, but each
        // chain's impl address is deterministic given its constants.
        // We still use Nick's factory-based CREATE3 so the verify script can recompute.
        bytes32 salt = keccak256(abi.encode(
            RecoveryDeployConfig.SALT_TOPUP_V2_IMPL,
            block.chainid,
            weth,
            dispatcher
        ));
        address predictedImpl = _predictImpl(salt);
        console.log("Predicted TopUpV2 impl : %s", predictedImpl);

        vm.startBroadcast(deployerPk);

        address impl = _deployCreate3(
            abi.encodePacked(type(TopUpV2).creationCode, abi.encode(weth, dispatcher)),
            salt
        );
        require(impl == predictedImpl, "impl address mismatch");

        vm.stopBroadcast();

        bytes memory upgradeCalldata = abi.encodeCall(
            BeaconFactory.upgradeBeaconImplementation,
            (impl)
        );

        console.log("chainId          : %s", block.chainid);
        console.log("weth             : %s", weth);
        console.log("dispatcher       : %s", dispatcher);
        console.log("beacon factory   : %s", beaconFactory);
        console.log("TopUpV2 impl     : %s", impl);
        console.log("TopUpV2 salt     :");
        console.logBytes32(salt);
        console.log("");
        console.log("3CP calldata - operating safe signs on this chain:");
        console.log("  target  : %s (BeaconFactory)", beaconFactory);
        console.log("  method  : upgradeBeaconImplementation(%s)", impl);
        console.log("  calldata:");
        console.logBytes(upgradeCalldata);
    }
}
