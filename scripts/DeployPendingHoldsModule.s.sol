// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { PendingHoldsModule } from "../src/modules/cash/PendingHoldsModule.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployPendingHoldsModule
 * @notice Deploys PendingHoldsModule implementation + UUPS proxy.
 *
 * @dev Run order:
 *   1. Run this script (PRIVATE_KEY deployer wallet) to produce the proxy address.
 *   2. Manually add `"PendingHoldsModule": "<proxy>"` to deployments.json.
 *   3. Run UpgradeCashModuleWithPendingHolds (Gnosis Safe) to upgrade CashModule and wire PHM.
 *   4. Run UpgradeCashLensWithPendingHolds (Gnosis Safe) to wire PHM into CashLens.
 *
 * @dev The CashModule address passed to initialize() is also the value stored in
 *      PendingHoldsModuleStorage.cashModuleCore (used to gate removeHold()).
 *      It can be updated later via setCashModuleCore() by CASH_MODULE_CONTROLLER_ROLE.
 */
contract DeployPendingHoldsModule is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        // Deploy implementation
        PendingHoldsModule phmImpl = new PendingHoldsModule(dataProvider);
        console.log("PendingHoldsModule impl:", address(phmImpl));

        // Deploy proxy — initialize wires in roleRegistry + cashModuleCore (= CashModule proxy)
        bytes memory initData = abi.encodeCall(
            PendingHoldsModule.initialize,
            (roleRegistry, cashModule)
        );
        address phmProxy = address(new UUPSProxy(address(phmImpl), initData));
        console.log("PendingHoldsModule proxy:", phmProxy);
        console.log(">>> Add to deployments.json: \"PendingHoldsModule\": \"%s\"", phmProxy);

        vm.stopBroadcast();
    }
}
