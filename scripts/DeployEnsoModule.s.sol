// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Utils } from "./utils/Utils.sol";
import { UUPSProxy } from "../src/UUPSProxy.sol";
import { EnsoSwapModule } from "../src/enso/EnsoSwapModule.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";

/**
 * @title DeployEnsoModule
 * @notice Standalone deploy of the EnsoSwapModule against an already-live stack (read from
 *         deployments.json). Whitelists it as a default module on the DataProvider and, where
 *         the DataProvider exposes a CashModule (OP), registers it so it can place withdrawal
 *         holds. Where `getCashModule() == 0` (e.g. the mainnet TradingSafe DataProvider) the
 *         CashModule registration is skipped — the module then executes swaps immediately.
 *
 *         The Enso Router address is baked into initialize(); repoint it later via
 *         `setEnsoRouter` (guarded by ENSO_SWAP_MODULE_ADMIN_ROLE) if Enso ships a new router.
 *
 * Run:
 *   source .env && ENV=dev forge script scripts/DeployEnsoModule.s.sol --rpc-url optimism --broadcast -vvv --verify
 */
contract DeployEnsoModule is Utils {
    // Enso Router V2 (same address on Ethereum and Optimism).
    address constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory deployments = readDeploymentFile();
        EtherFiDataProvider dataProvider = EtherFiDataProvider(
            stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider")
        );
        RoleRegistry roleRegistry = RoleRegistry(
            stdJson.readAddress(deployments, ".addresses.RoleRegistry")
        );

        vm.startBroadcast(pk);

        // Impl constructor reads getCashModule() off the DataProvider; the resulting immutable
        // decides whether the hold path is active on this chain.
        EnsoSwapModule module = new EnsoSwapModule(address(dataProvider));
        EnsoSwapModule enso = EnsoSwapModule(address(new UUPSProxy(
            address(module),
            abi.encodeWithSelector(EnsoSwapModule.initialize.selector, address(roleRegistry), ENSO_ROUTER)
        )));

        address[] memory modules = new address[](1);
        modules[0] = address(enso);
        bool[] memory enable = new bool[](1);
        enable[0] = true;

        dataProvider.configureDefaultModules(modules, enable);

        address cashModule = dataProvider.getCashModule();
        if (cashModule != address(0)) {
            ICashModule(cashModule).configureModulesCanRequestWithdraw(modules, enable);
        }

        roleRegistry.grantRole(enso.ADMIN_TIMELOCK_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("EnsoSwapModule:", address(enso));
        console.log("CashModule (hold path):", cashModule);
    }
}
