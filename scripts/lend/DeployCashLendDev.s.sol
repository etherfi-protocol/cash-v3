// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { ILendGateway } from "../../src/interfaces/ILendGateway.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title DeployCashLendDev
 * @notice Upgrades the existing Optimism dev Cash deployment in place and enables Lend integration
 * @dev This script is dev-only. PRIVATE_KEY must belong to the current dev admin recorded as both the Cash
 *      RoleRegistry owner and Aave test-instance admin. The same wallet deploys implementations, upgrades the
 *      existing proxies, configures LendGateway, and activates it on the existing Aave test Spoke.
 *
 *      The script registers every Spoke reserve, enables USDC for debit spend, sets the minimum health factor,
 *      and authorizes only DebtManager and TopUpDest. Asset-moving modules are handled by a separate rollout so
 *      this script never grants gateway authority to stale module bytecode.
 *
 *      CashModuleCore, CashModuleSetters, and CashLens use dynamically linked libraries. Forge deploys and
 *      links those libraries as part of the script run; retain the broadcast artifact for verification.
 *
 * Usage (drop --broadcast for simulation with the dev admin key):
 *   source .env && ENV=dev forge script \
 *     scripts/lend/DeployCashLendDev.s.sol:DeployCashLendDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract DeployCashLendDev is Utils {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant GATEWAY_IMPL_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayImpl/v1");
    bytes32 internal constant GATEWAY_PROXY_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayProxy/v1");
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
    }

    struct NewImplementations {
        address cashEventEmitter;
        address cashLens;
        address cashModuleCore;
        address cashModuleSetters;
        address debtManagerAdmin;
        address debtManagerCore;
        address hook;
        address topUpDest;
    }

    struct PreviousImplementations {
        address cashEventEmitter;
        address cashLens;
        address cashModuleCore;
        address cashModuleSetters;
        address debtManagerAdmin;
        address debtManagerCore;
        address hook;
        address topUpDest;
    }

    /// @dev Deploys implementations, upgrades the existing dev proxies, and configures Lend in one broadcast.
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        ExistingContracts memory existing = _readExistingContracts();
        string memory aaveJson = _readAaveDeployment();
        address spokeAddress = stdJson.readAddress(aaveJson, ".spoke");
        IAaveV4Spoke spoke = IAaveV4Spoke(spokeAddress);
        _validateDevAdmin(existing.roleRegistry, existing.cashModule, aaveJson, vm.addr(deployerPrivateKey));

        PreviousImplementations memory previous = _readPreviousImplementations(existing);

        vm.startBroadcast(deployerPrivateKey);

        (address gatewayImpl, address gatewayProxy) = _deployGateway(existing.dataProvider, existing.roleRegistry, spokeAddress);
        NewImplementations memory next = _deployImplementations(existing);
        _upgradeExistingContracts(existing, next);
        _configureGateway(existing, spoke, gatewayProxy);

        vm.stopBroadcast();

        _writeManifest(existing, previous, next, gatewayImpl, gatewayProxy, spokeAddress);
        _logSummary(gatewayImpl, gatewayProxy, next);
    }

    /// @dev Confirms PRIVATE_KEY has every permission used by this deployment.
    function _validateDevAdmin(address roleRegistry, address cashModule, string memory aaveJson, address deployer) internal view {
        RoleRegistry registry = RoleRegistry(roleRegistry);
        address cashAdmin = registry.owner();
        require(deployer == cashAdmin, "PRIVATE_KEY is not Cash dev admin");
        require(stdJson.readAddress(aaveJson, ".admin") == cashAdmin, "Cash and Aave dev admins differ");
        require(registry.hasRole(ICashModule(cashModule).CASH_MODULE_CONTROLLER_ROLE(), deployer), "dev admin missing CashModule controller role");
    }

    /// @dev Loads the existing Optimism dev Cash proxy addresses from the base deployment manifest.
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
        return contracts;
    }

    /// @dev Reads one named contract address from the base deployment JSON.
    function _readAddress(string memory json, string memory name) internal pure returns (address) {
        return stdJson.readAddress(json, string.concat(".addresses.", name));
    }

    /// @dev Loads the existing dev Aave v4 test-instance manifest for the active chain.
    function _readAaveDeployment() internal view returns (string memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/aave-v4-test.json");
        return vm.readFile(path);
    }

    /// @dev Reads the original implementations from the deployment file, or from the proxies on the first run.
    function _readPreviousImplementations(ExistingContracts memory c) internal view returns (PreviousImplementations memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
        PreviousImplementations memory previous;

        // On reruns, keep the original implementation addresses recorded by the first run.
        if (vm.exists(path)) {
            string memory json = vm.readFile(path);
            require(stdJson.readUint(json, ".chainId") == block.chainid, "deployment file chain mismatch");
            require(stdJson.readAddress(json, ".cashEventEmitter") == c.cashEventEmitter, "deployment file CashEventEmitter mismatch");
            require(stdJson.readAddress(json, ".cashLens") == c.cashLens, "deployment file CashLens mismatch");
            require(stdJson.readAddress(json, ".cashModule") == c.cashModule, "deployment file CashModule mismatch");
            require(stdJson.readAddress(json, ".debtManager") == c.debtManager, "deployment file DebtManager mismatch");
            require(stdJson.readAddress(json, ".etherFiHook") == c.hook, "deployment file EtherFiHook mismatch");
            require(stdJson.readAddress(json, ".topUpDest") == c.topUpDest, "deployment file TopUpDest mismatch");

            previous.cashEventEmitter = stdJson.readAddress(json, ".previousCashEventEmitterImpl");
            previous.cashLens = stdJson.readAddress(json, ".previousCashLensImpl");
            previous.cashModuleCore = stdJson.readAddress(json, ".previousCashModuleCoreImpl");
            previous.cashModuleSetters = stdJson.readAddress(json, ".previousCashModuleSettersImpl");
            previous.debtManagerAdmin = stdJson.readAddress(json, ".previousDebtManagerAdminImpl");
            previous.debtManagerCore = stdJson.readAddress(json, ".previousDebtManagerCoreImpl");
            previous.hook = stdJson.readAddress(json, ".previousEtherFiHookImpl");
            previous.topUpDest = stdJson.readAddress(json, ".previousTopUpDestImpl");

            // Each proxy must still use either its original implementation or the last Lend implementation.
            _requireKnownReference(_implementationOf(c.cashEventEmitter), previous.cashEventEmitter, stdJson.readAddress(json, ".cashEventEmitterImpl"));
            _requireKnownReference(_implementationOf(c.cashLens), previous.cashLens, stdJson.readAddress(json, ".cashLensImpl"));
            _requireKnownReference(_implementationOf(c.cashModule), previous.cashModuleCore, stdJson.readAddress(json, ".cashModuleCoreImpl"));
            _requireKnownReference(CashModuleCore(c.cashModule).getCashModuleSetters(), previous.cashModuleSetters, stdJson.readAddress(json, ".cashModuleSettersImpl"));
            _requireKnownReference(_implementationOf(c.debtManager), previous.debtManagerCore, stdJson.readAddress(json, ".debtManagerCoreImpl"));
            _requireKnownReference(IDebtManager(c.debtManager).getDebtManagerAdmin(), previous.debtManagerAdmin, stdJson.readAddress(json, ".debtManagerAdminImpl"));
            _requireKnownReference(_implementationOf(c.hook), previous.hook, stdJson.readAddress(json, ".etherFiHookImpl"));
            _requireKnownReference(_implementationOf(c.topUpDest), previous.topUpDest, stdJson.readAddress(json, ".topUpDestImpl"));
            return previous;
        }

        // If either deterministic gateway contract exists, an earlier deployment started without this file.
        address gatewayImpl = CREATE3.predictDeterministicAddress(GATEWAY_IMPL_SALT, NICKS_FACTORY);
        address gatewayProxy = CREATE3.predictDeterministicAddress(GATEWAY_PROXY_SALT, NICKS_FACTORY);
        require(gatewayImpl.code.length == 0 && gatewayProxy.code.length == 0, "Lend deployment already started; restore cash-lend.json");

        previous.cashEventEmitter = _implementationOf(c.cashEventEmitter);
        previous.cashLens = _implementationOf(c.cashLens);
        previous.cashModuleCore = _implementationOf(c.cashModule);
        previous.cashModuleSetters = CashModuleCore(c.cashModule).getCashModuleSetters();
        previous.debtManagerAdmin = IDebtManager(c.debtManager).getDebtManagerAdmin();
        previous.debtManagerCore = _implementationOf(c.debtManager);
        previous.hook = _implementationOf(c.hook);
        previous.topUpDest = _implementationOf(c.topUpDest);
        return previous;
    }

    /// @dev Rejects an implementation address that is not recorded in the deployment file.
    function _requireKnownReference(address current, address original, address lend) internal pure {
        require(current == original || current == lend, "current implementation not found in deployment file");
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }

    /// @dev Deterministically deploys and initializes the LendGateway implementation and proxy.
    function _deployGateway(address dataProvider, address roleRegistry, address spoke) internal returns (address, address) {
        address impl = _deployCreate3(abi.encodePacked(type(LendGateway).creationCode, abi.encode(dataProvider, spoke)), GATEWAY_IMPL_SALT);
        address proxy = _deployCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(impl, abi.encodeWithSelector(LendGateway.initialize.selector, roleRegistry))), GATEWAY_PROXY_SALT);

        require(address(LendGateway(proxy).etherFiDataProvider()) == dataProvider, "gateway data provider mismatch");
        require(address(LendGateway(proxy).spoke()) == spoke, "gateway spoke mismatch");
        return (impl, proxy);
    }

    /// @dev Deploys creation code through Nick's CREATE3 factory, or returns the existing deterministic address.
    function _deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address) {
        address deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);
        if (deployed.code.length != 0) return deployed;

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));
        bool success;
        if (proxy.code.length == 0) {
            (success,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(success, "CREATE3 proxy deployment failed");
        }

        (success,) = proxy.call(creationCode);
        require(success && deployed.code.length != 0, "CREATE3 deployment failed");
        return deployed;
    }

    /// @dev Deploys all new Cash implementations while preserving each proxy's existing constructor configuration.
    function _deployImplementations(ExistingContracts memory c) internal returns (NewImplementations memory) {
        NewImplementations memory implementations;
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
    function _upgradeExistingContracts(ExistingContracts memory c, NewImplementations memory next) internal {
        UUPSUpgradeable(c.cashModule).upgradeToAndCall(next.cashModuleCore, "");
        ICashModule(c.cashModule).setCashModuleSettersAddress(next.cashModuleSetters);
        UUPSUpgradeable(c.cashLens).upgradeToAndCall(next.cashLens, "");
        UUPSUpgradeable(c.cashEventEmitter).upgradeToAndCall(next.cashEventEmitter, "");
        UUPSUpgradeable(c.debtManager).upgradeToAndCall(next.debtManagerCore, "");
        IDebtManager(c.debtManager).setAdminImpl(next.debtManagerAdmin);
        UUPSUpgradeable(c.hook).upgradeToAndCall(next.hook, "");
        UUPSUpgradeable(c.topUpDest).upgradeToAndCall(next.topUpDest, "");
    }

    /// @dev Registers Aave reserves and wires the gateway into Cash and the existing Aave test Spoke.
    function _configureGateway(ExistingContracts memory c, IAaveV4Spoke spoke, address gatewayAddress) internal {
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

        // Apply the initial dev policy and authorize the two contracts that move Aave positions.
        address usdc = getChainConfig(vm.toString(block.chainid)).usdc;
        gateway.setSpendAsset(usdc, true);
        gateway.setMinHealthFactor(MIN_HEALTH_FACTOR);
        gateway.setDriver(c.debtManager, true);
        gateway.setDriver(c.topUpDest, true);

        // Set the CashModule gateway once, while rejecting an accidental replacement on reruns.
        ILendGateway configured = ICashModule(c.cashModule).getLendGateway();
        if (address(configured) == address(0)) ICashModule(c.cashModule).setLendGateway(gatewayAddress);
        else require(address(configured) == gatewayAddress, "CashModule gateway mismatch");

        // Allow the gateway to execute Aave operations for Safes that approve it.
        if (!spoke.isPositionManagerActive(gatewayAddress)) spoke.updatePositionManager(gatewayAddress, true);
    }

    /// @dev Records deployed addresses and prior implementations for verification and test rollback.
    function _writeManifest(ExistingContracts memory c, PreviousImplementations memory old, NewImplementations memory next, address gatewayImpl, address gatewayProxy, address spoke) internal {
        string memory object = "cash-lend-dev";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "deployer", vm.addr(vm.envUint("PRIVATE_KEY")));
        vm.serializeAddress(object, "admin", RoleRegistry(c.roleRegistry).owner());
        vm.serializeAddress(object, "spoke", spoke);
        vm.serializeAddress(object, "lendGateway", gatewayProxy);
        vm.serializeAddress(object, "lendGatewayImpl", gatewayImpl);
        vm.serializeAddress(object, "cashModule", c.cashModule);
        vm.serializeAddress(object, "cashModuleCoreImpl", next.cashModuleCore);
        vm.serializeAddress(object, "cashModuleSettersImpl", next.cashModuleSetters);
        vm.serializeAddress(object, "cashLens", c.cashLens);
        vm.serializeAddress(object, "cashLensImpl", next.cashLens);
        vm.serializeAddress(object, "cashEventEmitter", c.cashEventEmitter);
        vm.serializeAddress(object, "cashEventEmitterImpl", next.cashEventEmitter);
        vm.serializeAddress(object, "debtManager", c.debtManager);
        vm.serializeAddress(object, "debtManagerCoreImpl", next.debtManagerCore);
        vm.serializeAddress(object, "debtManagerAdminImpl", next.debtManagerAdmin);
        vm.serializeAddress(object, "etherFiHook", c.hook);
        vm.serializeAddress(object, "etherFiHookImpl", next.hook);
        vm.serializeAddress(object, "topUpDest", c.topUpDest);
        vm.serializeAddress(object, "topUpDestImpl", next.topUpDest);
        vm.serializeAddress(object, "previousCashModuleCoreImpl", old.cashModuleCore);
        vm.serializeAddress(object, "previousCashModuleSettersImpl", old.cashModuleSetters);
        vm.serializeAddress(object, "previousCashLensImpl", old.cashLens);
        vm.serializeAddress(object, "previousCashEventEmitterImpl", old.cashEventEmitter);
        vm.serializeAddress(object, "previousDebtManagerCoreImpl", old.debtManagerCore);
        vm.serializeAddress(object, "previousDebtManagerAdminImpl", old.debtManagerAdmin);
        vm.serializeAddress(object, "previousEtherFiHookImpl", old.hook);
        string memory output = vm.serializeAddress(object, "previousTopUpDestImpl", old.topUpDest);

        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
        vm.writeJson(output, path);
        console.log("Manifest:", path);
    }

    /// @dev Prints all newly deployed implementation and gateway addresses.
    function _logSummary(address gatewayImpl, address gatewayProxy, NewImplementations memory next) internal pure {
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
    }
}
