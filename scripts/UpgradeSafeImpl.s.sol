// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../src/safe/EtherFiSafeFactory.sol";
import { UpgradeableBeacon } from "../src/beacon-factory/BeaconFactory.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title UpgradeSafeImpl
 * @author ether.fi
 * @notice Deploys a new `EtherFiSafe` implementation and points the factory's beacon at it.
 *         One transaction upgrades EVERY safe on the chain at once.
 *
 * @dev Non-prod only. `upgradeBeaconImplementation` is `onlyRoleRegistryOwner`, and on OP prod
 *      that owner is the 8h `EtherFiTimelock` — use scripts/gnosis-txs/UpgradeSafeImplOP3CP.s.sol
 *      there. The ENV guard below is what stops this being run against prod by accident.
 *
 * Usage:
 *   ENV=dev PRIVATE_KEY=0x... forge script scripts/UpgradeSafeImpl.s.sol --rpc-url $RPC --broadcast
 */
contract UpgradeSafeImpl is Utils {
    using stdJson for string;

    function run() public {
        require(!isEqualString(getEnv(), "mainnet"), "ENV is mainnet (the default when unset) - set ENV=dev, or use gnosis-txs/UpgradeSafeImplOP3CP.s.sol for prod");

        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        EtherFiSafeFactory safeFactory = EtherFiSafeFactory(deployments.readAddress(".addresses.EtherFiSafeFactory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Fail before spending gas on an implementation the deployer cannot install.
        address owner = address(safeFactory.roleRegistry().owner());
        require(owner == deployer, "deployer is not the RoleRegistry owner - it cannot upgrade the beacon");

        address oldImpl = UpgradeableBeacon(safeFactory.beacon()).implementation();

        vm.startBroadcast(deployerPrivateKey);
        EtherFiSafe safeImpl = new EtherFiSafe(dataProvider);
        safeFactory.upgradeBeaconImplementation(address(safeImpl));
        vm.stopBroadcast();

        require(UpgradeableBeacon(safeFactory.beacon()).implementation() == address(safeImpl), "beacon did not move to the new implementation");
        require(address(safeImpl.dataProvider()) == dataProvider, "implementation bound to a different EtherFiDataProvider");

        console.log("old EtherFiSafe impl:", oldImpl);
        console.log("new EtherFiSafe impl:", address(safeImpl));
        console.log("WETH:                ", safeImpl.WETH());
        console.log("");
        console.log("Record the new impl under .addresses.EtherFiSafeImpl in the deployments file.");
    }
}
