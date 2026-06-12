// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { BeaconFactory } from "../src/beacon-factory/BeaconFactory.sol";
import { EtherFiOFTAdapter } from "../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../src/oft/EtherFiShadowOFT.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title UpgradeOFTPause
 * @author ether.fi
 * @notice Ships pause controls (COR-923) as a beacon upgrade: deploys the new beacon implementation
 *         for this chain's bridge ({EtherFiOFTAdapter} on mainnet, {EtherFiShadowOFT} on Optimism)
 *         and points the factory's beacon at it, so every existing and future per-asset proxy gains
 *         the `whenNotPaused` gate on `_debit`/`_credit` at once.
 * @dev Run once per chain. The new impl adds only {PausableUpgradeable}'s own ERC-7201 namespaced
 *      storage, so existing proxies keep their layout and read as UNPAUSED by default (proven by
 *      test_beaconUpgrade_preservesPauseState). Unlike the rate-limiter upgrade this is NOT
 *      fail-closed — bridges come up unpaused, so there is no follow-up config call needed to avoid
 *      bricking a live bridge.
 *
 *      Pause CONTROL lives ON the bridge: {pauseBridge}/{unpauseBridge} are gated by the shared
 *      RoleRegistry PAUSER/UNPAUSER roles (resolved off the config registry), with no registry in the
 *      control path. So this beacon upgrade is the ONLY contract change — the OFTConfigRegistry is
 *      untouched. After it, grant PAUSER/UNPAUSER to the chosen operators/Safe; "pause everything" is
 *      a Safe batch of {pauseBridge} calls (see {PauseOFTBridges}).
 *
 *      upgradeBeaconImplementation is gated to the RoleRegistry owner. In the EOA bring-up the
 *      deployer owns it and this broadcasts the upgrade directly; once handed to the protocol Safe,
 *      this script logs the calldata to submit from the Safe instead. Run:
 *
 *        PRIVATE_KEY=<deployer> forge script scripts/UpgradeOFTPause.s.sol --rpc-url <mainnet|optimism> --broadcast
 */
contract UpgradeOFTPause is Utils {
    /// @dev LayerZero V2 endpoint — same canonical address on Ethereum mainnet and Optimism.
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    function run() public {
        bool isMainnet = block.chainid == 1;
        require(isMainnet || block.chainid == 10, "run on Ethereum mainnet (1) or Optimism (10)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory deployments = readDeploymentFile();
        RoleRegistry roleRegistry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.OFTRoleRegistry"));
        address configRegistry = stdJson.readAddress(deployments, ".addresses.OFTConfigRegistry");
        string memory factoryKey = isMainnet ? ".addresses.OFTAdapterFactory" : ".addresses.ShadowOFTFactory";
        BeaconFactory factory = BeaconFactory(stdJson.readAddress(deployments, factoryKey));

        // Deploy the new beacon implementation for this chain's bridge type.
        vm.startBroadcast(pk);
        address newImpl = isMainnet ? address(new EtherFiOFTAdapter(LZ_ENDPOINT, configRegistry)) : address(new EtherFiShadowOFT(LZ_ENDPOINT, configRegistry));
        vm.stopBroadcast();

        console.log("OFT pause beacon upgrade on chainId", block.chainid);
        console.log("  factory:   ", address(factory));
        console.log("  new impl:  ", newImpl);
        console.log("  beacon:    ", factory.beacon());

        // Point the beacon at the new impl. Gated to the RoleRegistry owner.
        if (roleRegistry.owner() == deployer) {
            vm.broadcast(pk);
            factory.upgradeBeaconImplementation(newImpl);
            console.log("  upgraded beacon as RoleRegistry owner (EOA)");
        } else {
            console.log("  RoleRegistry owner is a Safe; submit this call FROM the Safe:");
            console.log("    target:  ", address(factory));
            console.logBytes(abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, newImpl));
        }

        // Persist the new impl address (preserves all existing keys).
        string memory implKey = isMainnet ? ".addresses.EtherFiOFTAdapterImpl" : ".addresses.EtherFiShadowOFTImpl";
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(vm.toString(newImpl), path, implKey);

        console.log("  NEXT: grant PAUSER/UNPAUSER to the operators/Safe. No registry upgrade needed.");
    }
}
