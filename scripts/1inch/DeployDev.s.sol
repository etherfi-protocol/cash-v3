// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { OneInchSwapModule } from "../../src/modules/oneinch-swap/OneInchSwapModule.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title 1inch — Dev all-in-one
 * @notice Single-EOA dev rollout for the 1inch integration. Redeploys every contract on this
 *         branch whose impl changed (DataProvider, DebtManager, CashModule, EtherFiSafe),
 *         upgrades the existing proxies / beacon, deploys the new OneInchSwapModule behind an
 *         ERC1967 proxy, and wires every admin call.
 *
 *         Assumes the calling EOA is the RoleRegistry owner + DataProvider admin + CashModule
 *         admin (true on dev). Idempotent re-runs OK — running twice deploys fresh impls and
 *         points the proxies at them.
 *
 *         Usage:
 *           ENV=dev PRIVATE_KEY=0x... \
 *             forge script scripts/1inch/DeployDev.s.sol --rpc-url <optimism_rpc> --broadcast
 */
contract DeployDevOneInch is Utils {
    address constant AGGREGATION_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant SIMPLE_SETTLEMENT_OP = 0x2Ad5004c60e16E54d5007C80CE329Adde5B51Ef5;
    /// Operating safe destination for `rescueFunds` on dev.
    address constant DEV_OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// Dev BE keeper EOA. Holds both `ONEINCH_SWAP_CANCEL_ROLE` and `ONEINCH_SWAP_REQUEST_ROLE`.
    /// Same EOA that drives `OpenOceanSwapModule` on dev today.
    address constant DEV_KEEPER = 0xf7F86fFA53DDe632a815048E4f9B3c1C9dE70671;

    struct Deployed {
        address dataProvider;
        address safeFactory;
        address roleRegistry;
        address cashModule;
        address debtManager;

        address newDataProviderImpl;
        address newDebtManagerCoreImpl;
        address newCashModuleCoreImpl;
        address newSafeImpl;

        address moduleImpl;
        address moduleProxy;
    }

    function _readExisting(Deployed memory d) internal view {
        string memory deployments = readDeploymentFile();
        d.dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        d.safeFactory  = stdJson.readAddress(deployments, ".addresses.EtherFiSafeFactory");
        d.roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        d.cashModule   = stdJson.readAddress(deployments, ".addresses.CashModule");
        d.debtManager  = stdJson.readAddress(deployments, ".addresses.DebtManager");
    }

    function _deployImpls(Deployed memory d) internal {
        d.newDataProviderImpl     = address(new EtherFiDataProvider());
        d.newDebtManagerCoreImpl  = address(new DebtManagerCore(d.dataProvider));
        d.newCashModuleCoreImpl   = address(new CashModuleCore(d.dataProvider));
        d.newSafeImpl             = address(new EtherFiSafe(d.dataProvider));
        d.moduleImpl              = address(new OneInchSwapModule(AGGREGATION_ROUTER, SIMPLE_SETTLEMENT_OP, d.dataProvider, DEV_OPERATING_SAFE));
        d.moduleProxy             = address(new ERC1967Proxy(d.moduleImpl, abi.encodeCall(OneInchSwapModule.initialize, (d.roleRegistry))));
    }

    function _upgradeProxies(Deployed memory d) internal {
        UUPSUpgradeable(d.dataProvider).upgradeToAndCall(d.newDataProviderImpl, "");
        UUPSUpgradeable(d.debtManager).upgradeToAndCall(d.newDebtManagerCoreImpl, "");
        UUPSUpgradeable(d.cashModule).upgradeToAndCall(d.newCashModuleCoreImpl, "");
        EtherFiSafeFactory(d.safeFactory).upgradeBeaconImplementation(d.newSafeImpl);
    }

    function _wireModule(Deployed memory d) internal {
        address[] memory modules = new address[](1);
        modules[0] = d.moduleProxy;
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        EtherFiDataProvider(d.dataProvider).configureModules(modules, yes);
        EtherFiDataProvider(d.dataProvider).configureDefaultModules(modules, yes);
        ICashModule(d.cashModule).configureModulesCanRequestWithdraw(modules, yes);
        EtherFiDataProvider(d.dataProvider).setOneInchSwapModule(d.moduleProxy);

        // Grants both 1inch roles to the dev keeper. `ONEINCH_SWAP_REQUEST_ROLE` is mandatory for
        // any `requestSwap` call; `ONEINCH_SWAP_CANCEL_ROLE` is the role-keeper cancel path.
        // Replace the placeholder before running.
        OneInchSwapModule m = OneInchSwapModule(d.moduleProxy);
        IRoleRegistry(d.roleRegistry).grantRole(m.ONEINCH_SWAP_REQUEST_ROLE(), DEV_KEEPER);
        IRoleRegistry(d.roleRegistry).grantRole(m.ONEINCH_SWAP_CANCEL_ROLE(),  DEV_KEEPER);
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        Deployed memory d;
        _readExisting(d);

        vm.startBroadcast(deployerPrivateKey);
        _deployImpls(d);
        _upgradeProxies(d);
        _wireModule(d);
        vm.stopBroadcast();

        string memory deploymentsPath = string.concat(
            vm.projectRoot(),
            "/deployments/", getEnv(), "/",
            vm.toString(block.chainid), "/deployments.json"
        );
        vm.writeJson(
            string.concat('"', vm.toString(d.moduleProxy), '"'),
            deploymentsPath,
            ".addresses.OneInchSwapModule"
        );

        console.log("=== Impls ===");
        console.log("DataProvider          :", d.newDataProviderImpl);
        console.log("DebtManagerCore       :", d.newDebtManagerCoreImpl);
        console.log("CashModuleCore        :", d.newCashModuleCoreImpl);
        console.log("EtherFiSafe           :", d.newSafeImpl);
        console.log("OneInchSwapModule impl:", d.moduleImpl);
        console.log("=== Proxies ===");
        console.log("OneInchSwapModule     :", d.moduleProxy);
    }
}
