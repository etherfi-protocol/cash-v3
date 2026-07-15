// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { Utils } from "../utils/Utils.sol";
import { CashLendDevModules } from "./CashLendDevModules.sol";

/**
 * @title DeployCashLendDev
 * @notice Upgrades the existing Optimism dev Cash deployment in place and enables Lend
 * @dev Dev-only. The CLI sender must be the dev admin: the Cash RoleRegistry owner, who is also the
 *      Aave test-instance admin. See scripts/lend/README.md for the full runbook and file glossary.
 *
 *      The script only runs from a clean starting point: every proxy must be at its rollback-baseline
 *      implementation and no deployment record may exist. If a broadcast dies partway, run
 *      RollbackCashLendDev (it skips already-restored references), delete cash-lend.json, and rerun.
 *
 *      Run scripts/lend/check-pending-withdrawals.sh first. It scans every Safe in parallel for a
 *      pending withdrawal paying out to an old module, which this deploy would strand. Doing that
 *      scan in-script takes 20+ minutes because forge fetches each Safe's state sequentially.
 *
 *      CashModuleCore, CashModuleSetters, and CashLens use dynamically linked libraries. Forge deploys
 *      and links those libraries as part of the script run; retain the broadcast artifact for verification.
 *
 * Usage (drop --broadcast for simulation):
 *   source .env && ENV=dev forge script \
 *     scripts/lend/DeployCashLendDev.s.sol:DeployCashLendDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract DeployCashLendDev is Utils {
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant MIN_HEALTH_FACTOR = 1.05e18;

    struct ExistingContracts {
        address cashEventEmitter;
        address cashLens;
        address cashModule;
        address dataProvider;
        address debtManager;
        address hook;
        address roleRegistry;
        address topUpDest;
        CashLendDevModules.OldModules modules;
    }

    struct Implementations {
        address cashEventEmitter;
        address cashLens;
        address cashModuleCore;
        address cashModuleSetters;
        address debtManagerAdmin;
        address debtManagerCore;
        address hook;
        address topUpDest;
    }

    /// @dev Validates the clean starting point, then deploys, upgrades, and activates Lend in one broadcast.
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        ExistingContracts memory existing = _readExistingContracts();
        string memory aaveJson = _readAaveDeployment();
        address spokeAddress = stdJson.readAddress(aaveJson, ".spoke");

        // Stop before broadcasting if the sender, chain state, or module configuration is unexpected.
        _validateDevAdmin(existing, aaveJson, tx.origin);
        CashLendDevModules.validateOld(existing.modules);
        CashLendDevModules.requireDevPolicy(existing.dataProvider, existing.cashModule, existing.modules);
        address previousLiquifierImplementation = _requireBaselineState(existing);

        vm.startBroadcast();

        // Direct module storage cannot move to a new address, so deploy new copies with the old configuration.
        CashLendDevModules.NewModules memory modules = CashLendDevModules.deployNew(existing.modules, existing.dataProvider, existing.debtManager);
        CashLendDevModules.copyLiquidQueues(existing.roleRegistry, existing.modules, modules);

        (address gatewayImpl, address gatewayProxy) = _deployGateway(existing.dataProvider, existing.roleRegistry, spokeAddress);
        Implementations memory next = _deployImplementations(existing);

        // Upgrade existing proxies. The liquifier keeps its proxy and only gets the new implementation.
        _upgradeExistingContracts(existing, next);
        UUPSUpgradeable(existing.modules.liquifier).upgradeToAndCall(modules.liquifierImplementation, "");

        // Configure every gateway driver before enabling the new modules or routing Safes through Lend.
        _configureGateway(existing, IAaveV4Spoke(spokeAddress), gatewayProxy, modules);

        // Swap the new modules in, then activate Lend last so no Safe reaches a half-configured gateway.
        CashLendDevModules.activate(existing.dataProvider, existing.cashModule, existing.modules, modules);
        IAaveV4Spoke(spokeAddress).updatePositionManager(gatewayProxy, true);
        ICashModule(existing.cashModule).setLendGateway(gatewayProxy);

        vm.stopBroadcast();

        CashLendDevModules.verifyNewConfig(existing.dataProvider, existing.debtManager, existing.modules, modules);
        _writeDeploymentRecord(existing, next, modules, previousLiquifierImplementation, gatewayImpl, gatewayProxy, spokeAddress);
        _logSummary(gatewayImpl, gatewayProxy, next, modules);
    }

    /// @dev Confirms the CLI sender has every permission used by this deployment.
    function _validateDevAdmin(ExistingContracts memory existing, string memory aaveJson, address deployer) internal view {
        RoleRegistry registry = RoleRegistry(existing.roleRegistry);
        address cashAdmin = registry.owner();
        require(deployer == cashAdmin, "sender is not Cash dev admin");
        require(stdJson.readAddress(aaveJson, ".admin") == cashAdmin, "Cash and Aave dev admins differ");
        require(registry.hasRole(ICashModule(existing.cashModule).CASH_MODULE_CONTROLLER_ROLE(), deployer), "dev admin missing CashModule controller role");
        require(registry.hasRole(EtherFiDataProvider(existing.dataProvider).DATA_PROVIDER_ADMIN_ROLE(), deployer), "dev admin missing DataProvider admin role");
    }

    /// @dev Loads the existing Optimism dev Cash proxy addresses from the base deployment file.
    function _readExistingContracts() internal view returns (ExistingContracts memory) {
        string memory json = readDeploymentFile();
        ExistingContracts memory contracts;
        contracts.cashEventEmitter = _readAddress(json, "CashEventEmitter");
        contracts.cashLens = _readAddress(json, "CashLens");
        contracts.cashModule = _readAddress(json, "CashModule");
        contracts.dataProvider = _readAddress(json, "EtherFiDataProvider");
        contracts.debtManager = _readAddress(json, "DebtManager");
        contracts.hook = _readAddress(json, "EtherFiHook");
        contracts.roleRegistry = _readAddress(json, "RoleRegistry");
        contracts.topUpDest = _readAddress(json, "TopUpDest");
        contracts.modules = CashLendDevModules.readOld(json);
        return contracts;
    }

    /// @dev Reads one named contract address from the base deployment JSON.
    function _readAddress(string memory json, string memory name) internal pure returns (address) {
        return stdJson.readAddress(json, string.concat(".addresses.", name));
    }

    /// @dev Loads the existing dev Aave v4 test-instance file for the active chain.
    function _readAaveDeployment() internal view returns (string memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/aave-v4-test.json");
        return vm.readFile(path);
    }

    /// @dev Requires a clean starting point: no deployment record, and every reference at its baseline value.
    function _requireBaselineState(ExistingContracts memory c) internal view returns (address) {
        require(!vm.exists(_deploymentRecordPath()), "cash-lend.json exists; roll back and delete it first");

        string memory baseline = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend-rollback-baseline.json"));
        require(stdJson.readUint(baseline, ".chainId") == block.chainid, "rollback baseline chain mismatch");
        require(_implementationOf(c.cashEventEmitter) == stdJson.readAddress(baseline, ".cashEventEmitterImpl"), "CashEventEmitter differs from baseline");
        require(_implementationOf(c.cashLens) == stdJson.readAddress(baseline, ".cashLensImpl"), "CashLens differs from baseline");
        require(_implementationOf(c.cashModule) == stdJson.readAddress(baseline, ".cashModuleCoreImpl"), "CashModule differs from baseline");
        require(CashModuleCore(c.cashModule).getCashModuleSetters() == stdJson.readAddress(baseline, ".cashModuleSettersImpl"), "CashModule setters differ from baseline");
        require(_implementationOf(c.debtManager) == stdJson.readAddress(baseline, ".debtManagerCoreImpl"), "DebtManager differs from baseline");
        require(IDebtManager(c.debtManager).getDebtManagerAdmin() == stdJson.readAddress(baseline, ".debtManagerAdminImpl"), "DebtManager admin differs from baseline");
        require(_implementationOf(c.hook) == stdJson.readAddress(baseline, ".etherFiHookImpl"), "EtherFiHook differs from baseline");
        require(_implementationOf(c.topUpDest) == stdJson.readAddress(baseline, ".topUpDestImpl"), "TopUpDest differs from baseline");

        address[] memory oldModules = CashLendDevModules.oldAddresses(c.modules);
        address[7] memory baselineModules = [stdJson.readAddress(baseline, ".openOcean"), stdJson.readAddress(baseline, ".liquid"), stdJson.readAddress(baseline, ".liquidReferrer"), stdJson.readAddress(baseline, ".frax"), stdJson.readAddress(baseline, ".stake"), stdJson.readAddress(baseline, ".midas"), stdJson.readAddress(baseline, ".beHype")];
        for (uint256 i = 0; i < 7; ++i) {
            require(oldModules[i] == baselineModules[i], "old module differs from baseline");
        }
        require(c.modules.liquifier == stdJson.readAddress(baseline, ".liquifier"), "liquifier differs from baseline");
        address previousLiquifierImplementation = stdJson.readAddress(baseline, ".liquifierImplementation");
        require(_implementationOf(c.modules.liquifier) == previousLiquifierImplementation, "liquifier implementation differs from baseline");
        return previousLiquifierImplementation;
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }

    /// @dev Deploys and initializes the LendGateway implementation and proxy.
    function _deployGateway(address dataProvider, address roleRegistry, address spoke) internal returns (address, address) {
        address impl = address(new LendGateway(dataProvider, spoke));
        address proxy = address(new UUPSProxy(impl, abi.encodeWithSelector(LendGateway.initialize.selector, roleRegistry)));
        return (impl, proxy);
    }

    /// @dev Deploys all new Cash implementations while preserving each proxy's existing constructor configuration.
    function _deployImplementations(ExistingContracts memory c) internal returns (Implementations memory) {
        Implementations memory implementations;
        implementations.cashModuleCore = address(new CashModuleCore(c.dataProvider));
        implementations.cashModuleSetters = address(new CashModuleSetters(c.dataProvider));
        implementations.cashLens = address(new CashLens(c.cashModule, c.dataProvider));
        implementations.cashEventEmitter = address(new CashEventEmitter(c.cashModule));
        implementations.debtManagerCore = address(new DebtManagerCore(c.dataProvider));
        implementations.debtManagerAdmin = address(new DebtManagerAdmin(c.dataProvider));
        implementations.hook = address(new EtherFiHook(c.dataProvider));

        address weth = getChainConfig(vm.toString(block.chainid)).weth;
        implementations.topUpDest = address(new TopUpDest(c.dataProvider, weth));
        return implementations;
    }

    /// @dev Upgrades every existing Cash proxy and updates delegated implementation pointers in place.
    function _upgradeExistingContracts(ExistingContracts memory c, Implementations memory next) internal {
        UUPSUpgradeable(c.cashModule).upgradeToAndCall(next.cashModuleCore, "");
        ICashModule(c.cashModule).setCashModuleSettersAddress(next.cashModuleSetters);
        UUPSUpgradeable(c.cashLens).upgradeToAndCall(next.cashLens, "");
        UUPSUpgradeable(c.cashEventEmitter).upgradeToAndCall(next.cashEventEmitter, "");
        UUPSUpgradeable(c.debtManager).upgradeToAndCall(next.debtManagerCore, "");
        IDebtManager(c.debtManager).setAdminImpl(next.debtManagerAdmin);
        UUPSUpgradeable(c.hook).upgradeToAndCall(next.hook, "");
        UUPSUpgradeable(c.topUpDest).upgradeToAndCall(next.topUpDest, "");
    }

    /// @dev Registers Aave reserves and configures every gateway driver before activation.
    function _configureGateway(ExistingContracts memory c, IAaveV4Spoke spoke, address gatewayAddress, CashLendDevModules.NewModules memory modules) internal {
        // Grant the existing dev admin permission to manage LendGateway configuration.
        LendGateway gateway = LendGateway(gatewayAddress);
        RoleRegistry registry = RoleRegistry(c.roleRegistry);
        address admin = registry.owner();
        bytes32 adminRole = gateway.LEND_GATEWAY_ADMIN_ROLE();
        if (!registry.hasRole(adminRole, admin)) registry.grantRole(adminRole, admin);

        // Mirror every Aave Spoke reserve ID into the gateway's asset registry.
        uint256 reserveCount = spoke.getReserveCount();
        for (uint256 reserveId = 0; reserveId < reserveCount; ++reserveId) {
            gateway.setReserveId(spoke.getReserve(reserveId).underlying, reserveId);
        }

        // Apply the initial dev policy and enable every contract that calls the gateway.
        address usdc = getChainConfig(vm.toString(block.chainid)).usdc;
        gateway.setSpendAsset(usdc, true);
        gateway.setMinHealthFactor(MIN_HEALTH_FACTOR);
        gateway.setDriver(c.debtManager, true);
        gateway.setDriver(c.topUpDest, true);
        CashLendDevModules.enableDrivers(gateway, c.modules, modules);
    }

    /// @dev Returns the deployment record path for the active dev chain.
    function _deploymentRecordPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
    }

    /// @dev Records everything this run deployed, for verification and rollback.
    function _writeDeploymentRecord(ExistingContracts memory c, Implementations memory next, CashLendDevModules.NewModules memory modules, address previousLiquifierImplementation, address gatewayImpl, address gatewayProxy, address spoke) internal {
        string memory object = "cash-lend-dev";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "deployer", tx.origin);
        vm.serializeAddress(object, "admin", RoleRegistry(c.roleRegistry).owner());
        vm.serializeAddress(object, "spoke", spoke);
        vm.serializeAddress(object, "lendGateway", gatewayProxy);
        vm.serializeAddress(object, "lendGatewayImpl", gatewayImpl);
        vm.serializeAddress(object, "cashModuleCoreImpl", next.cashModuleCore);
        vm.serializeAddress(object, "cashModuleSettersImpl", next.cashModuleSetters);
        vm.serializeAddress(object, "cashLensImpl", next.cashLens);
        vm.serializeAddress(object, "cashEventEmitterImpl", next.cashEventEmitter);
        vm.serializeAddress(object, "debtManagerCoreImpl", next.debtManagerCore);
        vm.serializeAddress(object, "debtManagerAdminImpl", next.debtManagerAdmin);
        vm.serializeAddress(object, "etherFiHookImpl", next.hook);
        vm.serializeAddress(object, "topUpDestImpl", next.topUpDest);
        vm.serializeAddress(object, "newModules", CashLendDevModules.newAddresses(modules));
        vm.serializeAddress(object, "previousLiquifierImplementation", previousLiquifierImplementation);
        string memory output = vm.serializeAddress(object, "liquifierImplementation", modules.liquifierImplementation);

        vm.writeJson(output, _deploymentRecordPath());
        console.log("Deployment record:", _deploymentRecordPath());
    }

    /// @dev Prints all newly deployed addresses.
    function _logSummary(address gatewayImpl, address gatewayProxy, Implementations memory next, CashLendDevModules.NewModules memory modules) internal pure {
        console.log("LendGateway proxy:       ", gatewayProxy);
        console.log("LendGateway impl:        ", gatewayImpl);
        console.log("CashModuleCore impl:     ", next.cashModuleCore);
        console.log("CashModuleSetters impl:  ", next.cashModuleSetters);
        console.log("CashLens impl:           ", next.cashLens);
        console.log("CashEventEmitter impl:   ", next.cashEventEmitter);
        console.log("DebtManagerCore impl:    ", next.debtManagerCore);
        console.log("DebtManagerAdmin impl:   ", next.debtManagerAdmin);
        console.log("EtherFiHook impl:        ", next.hook);
        console.log("TopUpDest impl:          ", next.topUpDest);
        console.log("OpenOcean module:        ", modules.openOcean);
        console.log("Liquid module:           ", modules.liquid);
        console.log("Liquid referrer module:  ", modules.liquidReferrer);
        console.log("Frax module:             ", modules.frax);
        console.log("Stake module:            ", modules.stake);
        console.log("Midas module:            ", modules.midas);
        console.log("BeHYPE module:           ", modules.beHype);
        console.log("Liquifier impl:          ", modules.liquifierImplementation);
    }
}
