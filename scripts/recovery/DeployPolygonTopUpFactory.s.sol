// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig } from "./RecoveryDeployConfig.sol";

/**
 * @notice Phase 0.5 — make the reserved Polygon proxy a working TopUp `BeaconFactory`.
 *
 *         The canonical factory slot `0xF4e147…d8CF` already exists on Polygon as a *reserved*
 *         UUPS proxy (labelled `EtherFiSafeFactory`). The recovery dispatcher hard-depends on a
 *         TopUp factory at that address (its `getDeterministicAddress` resolves user addresses via
 *         CREATE3 with the factory as deployer). This script deploys the two impls and prints the
 *         `upgradeToAndCall` 3CP calldata to point the reserved proxy at `TopUpFactory`.
 *
 *         The reserved proxy is already initialized (`roleRegistry()` returns a real value on-chain
 *         — it was set by `EtherFiPlaceholder.initialize`, consuming OZ initializer v1). So
 *         `TopUpFactory.initialize` (also an `initializer`) would revert with `InvalidInitialization`.
 *         `TopUpFactory.reinitialize(address)` (`reinitializer(2)`) is the entrypoint for this upgrade:
 *         it re-wires the beacon while reading `roleRegistry()` from existing storage (not re-supplied).
 *         This script prints the exact `upgradeToAndCall(factoryImpl, reinitialize(topUpImpl))` calldata
 *         for the operating safe (RoleRegistry `onlyUpgrader`) to 3CP-sign. The upgrade MUST stay atomic
 *         (`upgradeToAndCall`, not a split upgradeTo + reinitialize) so `msg.sender` during the inner
 *         call is the authorized upgrader.
 *
 * Env:
 *   WPOL  — Polygon wrapped native (TopUp ctor immutable). Default below if unset.
 *
 * Usage:
 *   ENV=mainnet WPOL=0x0d50... forge script scripts/recovery/DeployPolygonTopUpFactory.s.sol \
 *     --rpc-url $POLYGON_RPC --broadcast --verify
 */
contract DeployPolygonTopUpFactory is Utils {
    // Reserved UUPS proxy at the canonical CREATE3 factory address (same on every chain).
    address constant RESERVED_FACTORY_PROXY = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;
    // WPOL / WMATIC (rebranded; same address).
    address constant DEFAULT_WPOL = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    function run() external {
        require(block.chainid == 137, "must be Polygon");

        address wpol = vm.envOr("WPOL", DEFAULT_WPOL);
        require(wpol.code.length > 0, "WPOL has no code on this chain");
        require(RESERVED_FACTORY_PROXY.code.length > 0, "reserved factory proxy not found");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        require(roleRegistry != address(0), "RoleRegistry not found in deployments.json");

        vm.startBroadcast();

        // Impl addresses are ephemeral (upgradeable) -> regular CREATE, not CREATE3.
        TopUpFactory factoryImpl = new TopUpFactory();
        TopUp topUpImpl = new TopUp(wpol);

        vm.stopBroadcast();

        // Post-deploy sanity on the impls themselves.
        require(address(factoryImpl).code.length > 0, "factory impl deploy failed");
        require(address(topUpImpl).code.length > 0, "topup impl deploy failed");

        // ── Upgrade 3CP calldata ────────────────────────────────────────────────────────────────
        // reinitialize(address) is reinitializer(2): valid on the already-initialized reserved proxy.
        // It reads roleRegistry() from existing storage, so only the TopUp impl is supplied here.
        bytes memory reinitData = abi.encodeCall(TopUpFactory.reinitialize, (address(topUpImpl)));
        bytes memory upgradeCalldata = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", address(factoryImpl), reinitData
        );

        console.log("chainId                 : %s", block.chainid);
        console.log("WPOL (TopUp.weth)       : %s", wpol);
        console.log("RoleRegistry            : %s", roleRegistry);
        console.log("TopUpFactory impl       : %s", address(factoryImpl));
        console.log("TopUp impl              : %s", address(topUpImpl));
        console.log("Factory impl code hash  :");
        console.logBytes32(keccak256(address(factoryImpl).code));
        console.log("TopUp impl code hash    :");
        console.logBytes32(keccak256(address(topUpImpl).code));
        console.log("");
        console.log("UPGRADE 3CP (signer = RoleRegistry UPGRADER; onlyUpgrader):");
        console.log("  target : %s (reserved factory proxy)", RESERVED_FACTORY_PROXY);
        console.log("  method : upgradeToAndCall(factoryImpl, reinitialize(topUpImpl))");
        console.log("  note   : atomic upgrade+reinit; reinitialize reads roleRegistry() from storage");
        console.log("  calldata:");
        console.logBytes(upgradeCalldata);
    }
}
