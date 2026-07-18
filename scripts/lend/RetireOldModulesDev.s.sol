// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";
import { CashLendDevModules } from "./CashLendDevModules.sol";

/**
 * @title RetireOldModulesDev
 * @notice Retires the seven pre-Lend modules once every Safe runs on the new copies: revokes their
 *         withdraw-requester flags and removes them from the default-module and whitelist registries.
 * @dev Dev-only, run by the dev admin. A pending Cash withdrawal paying out to an old module strands when
 *      that module is retired (see the LendDevWithdrawals rehearsal test), so run
 *      scripts/lend/check-pending-withdrawals.sh immediately before broadcasting and confirm with
 *      PENDING_WITHDRAWALS_CHECKED=true.
 *
 * Usage:
 *   source .env && scripts/lend/check-pending-withdrawals.sh "$OPTIMISM_RPC"
 *   source .env && ENV=dev PENDING_WITHDRAWALS_CHECKED=true forge script \
 *     scripts/lend/RetireOldModulesDev.s.sol:RetireOldModulesDev --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract RetireOldModulesDev is Utils {
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");
        require(vm.envOr("PENDING_WITHDRAWALS_CHECKED", false), "run check-pending-withdrawals.sh, then set PENDING_WITHDRAWALS_CHECKED=true");

        string memory baseJson = readDeploymentFile();
        address cashModule = stdJson.readAddress(baseJson, ".addresses.CashModule");
        address dataProvider = stdJson.readAddress(baseJson, ".addresses.EtherFiDataProvider");
        address[] memory oldModules = CashLendDevModules.oldAddresses(CashLendDevModules.readOld(baseJson));
        require(RoleRegistry(stdJson.readAddress(baseJson, ".addresses.RoleRegistry")).owner() == vm.addr(vm.envUint("PRIVATE_KEY")), "sender is not Cash dev admin");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _retire(dataProvider, cashModule, oldModules);
        vm.stopBroadcast();

        console.log("Old modules retired");
    }

    /// @dev The retire calls; the deployed-sanity rehearsal test drives this exact path on a fork.
    function _retire(address dataProvider, address cashModule, address[] memory oldModules) internal {
        bool[] memory no = new bool[](oldModules.length);
        ICashModule(cashModule).configureModulesCanRequestWithdraw(oldModules, no);
        EtherFiDataProvider(dataProvider).configureDefaultModules(oldModules, no);
        EtherFiDataProvider(dataProvider).configureModules(oldModules, no);
    }
}
