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
 *      and enables DebtManager and TopUpDest as drivers. Asset-moving modules are handled by a separate rollout
 *      so this script never grants gateway authority to stale module bytecode.
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

    bytes32 internal expectedGatewayImplRuntimeCodeHash;
    bytes32 internal expectedGatewayProxyRuntimeCodeHash;

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
        _setExpectedGatewayRuntimeCodeHashes(existing.dataProvider, existing.roleRegistry, spokeAddress);

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

    /// @dev Reads the original implementation addresses from the committed rollback file.
    function _readPreviousImplementations(ExistingContracts memory c) internal view returns (PreviousImplementations memory) {
        string memory baselinePath = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend-rollback-baseline.json");
        string memory baseline = vm.readFile(baselinePath);
        require(stdJson.readUint(baseline, ".chainId") == block.chainid, "rollback file chain mismatch");

        PreviousImplementations memory previous;
        previous.cashEventEmitter = stdJson.readAddress(baseline, ".cashEventEmitterImpl");
        previous.cashLens = stdJson.readAddress(baseline, ".cashLensImpl");
        previous.cashModuleCore = stdJson.readAddress(baseline, ".cashModuleCoreImpl");
        previous.cashModuleSetters = stdJson.readAddress(baseline, ".cashModuleSettersImpl");
        previous.debtManagerAdmin = stdJson.readAddress(baseline, ".debtManagerAdminImpl");
        previous.debtManagerCore = stdJson.readAddress(baseline, ".debtManagerCoreImpl");
        previous.hook = stdJson.readAddress(baseline, ".etherFiHookImpl");
        previous.topUpDest = stdJson.readAddress(baseline, ".topUpDestImpl");
        _requireBaselineCodeHashes(previous, baseline);

        string memory deploymentPath = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
        if (vm.exists(deploymentPath)) {
            string memory deployment = vm.readFile(deploymentPath);
            require(stdJson.readUint(deployment, ".chainId") == block.chainid, "deployment file chain mismatch");
            require(stdJson.readAddress(deployment, ".cashModule") == c.cashModule, "deployment file CashModule mismatch");
            require(stdJson.readAddress(deployment, ".debtManager") == c.debtManager, "deployment file DebtManager mismatch");

            // Each proxy must still use either its original implementation or the last Lend implementation.
            _requireKnownReference(_implementationOf(c.cashEventEmitter), previous.cashEventEmitter, stdJson.readAddress(deployment, ".cashEventEmitterImpl"));
            _requireKnownReference(_implementationOf(c.cashLens), previous.cashLens, stdJson.readAddress(deployment, ".cashLensImpl"));
            _requireKnownReference(_implementationOf(c.cashModule), previous.cashModuleCore, stdJson.readAddress(deployment, ".cashModuleCoreImpl"));
            _requireKnownReference(CashModuleCore(c.cashModule).getCashModuleSetters(), previous.cashModuleSetters, stdJson.readAddress(deployment, ".cashModuleSettersImpl"));
            _requireKnownReference(_implementationOf(c.debtManager), previous.debtManagerCore, stdJson.readAddress(deployment, ".debtManagerCoreImpl"));
            _requireKnownReference(IDebtManager(c.debtManager).getDebtManagerAdmin(), previous.debtManagerAdmin, stdJson.readAddress(deployment, ".debtManagerAdminImpl"));
            _requireKnownReference(_implementationOf(c.hook), previous.hook, stdJson.readAddress(deployment, ".etherFiHookImpl"));
            _requireKnownReference(_implementationOf(c.topUpDest), previous.topUpDest, stdJson.readAddress(deployment, ".topUpDestImpl"));
            return previous;
        }

        // Without a deployment file, the chain must still be exactly at the committed original versions.
        address gatewayImpl = CREATE3.predictDeterministicAddress(GATEWAY_IMPL_SALT, NICKS_FACTORY);
        address gatewayProxy = CREATE3.predictDeterministicAddress(GATEWAY_PROXY_SALT, NICKS_FACTORY);
        require(gatewayImpl.code.length == 0 && gatewayProxy.code.length == 0, "Lend deployment already started; restore cash-lend.json");
        require(_implementationOf(c.cashEventEmitter) == previous.cashEventEmitter, "CashEventEmitter differs from rollback file");
        require(_implementationOf(c.cashLens) == previous.cashLens, "CashLens differs from rollback file");
        require(_implementationOf(c.cashModule) == previous.cashModuleCore, "CashModule differs from rollback file");
        require(CashModuleCore(c.cashModule).getCashModuleSetters() == previous.cashModuleSetters, "CashModule setters differ from rollback file");
        require(_implementationOf(c.debtManager) == previous.debtManagerCore, "DebtManager differs from rollback file");
        require(IDebtManager(c.debtManager).getDebtManagerAdmin() == previous.debtManagerAdmin, "DebtManager admin differs from rollback file");
        require(_implementationOf(c.hook) == previous.hook, "EtherFiHook differs from rollback file");
        require(_implementationOf(c.topUpDest) == previous.topUpDest, "TopUpDest differs from rollback file");
        return previous;
    }

    /// @dev Confirms the committed original implementation addresses still have the reviewed runtime code.
    function _requireBaselineCodeHashes(PreviousImplementations memory previous, string memory baseline) internal view {
        require(previous.cashEventEmitter.codehash == stdJson.readBytes32(baseline, ".cashEventEmitterCodeHash"), "CashEventEmitter rollback code changed");
        require(previous.cashLens.codehash == stdJson.readBytes32(baseline, ".cashLensCodeHash"), "CashLens rollback code changed");
        require(previous.cashModuleCore.codehash == stdJson.readBytes32(baseline, ".cashModuleCoreCodeHash"), "CashModule rollback code changed");
        require(previous.cashModuleSetters.codehash == stdJson.readBytes32(baseline, ".cashModuleSettersCodeHash"), "CashModule setters rollback code changed");
        require(previous.debtManagerAdmin.codehash == stdJson.readBytes32(baseline, ".debtManagerAdminCodeHash"), "DebtManager admin rollback code changed");
        require(previous.debtManagerCore.codehash == stdJson.readBytes32(baseline, ".debtManagerCoreCodeHash"), "DebtManager rollback code changed");
        require(previous.hook.codehash == stdJson.readBytes32(baseline, ".etherFiHookCodeHash"), "EtherFiHook rollback code changed");
        require(previous.topUpDest.codehash == stdJson.readBytes32(baseline, ".topUpDestCodeHash"), "TopUpDest rollback code changed");
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
        bytes memory implCode = abi.encodePacked(type(LendGateway).creationCode, abi.encode(dataProvider, spoke));
        address predictedImpl = CREATE3.predictDeterministicAddress(GATEWAY_IMPL_SALT, NICKS_FACTORY);
        bytes memory proxyCode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(predictedImpl, abi.encodeWithSelector(LendGateway.initialize.selector, roleRegistry)));
        _requireGatewayCodeVersion(keccak256(implCode), keccak256(proxyCode));

        address impl = _deployCreate3(implCode, GATEWAY_IMPL_SALT);
        address proxy = _deployCreate3(proxyCode, GATEWAY_PROXY_SALT);
        LendGateway gateway = LendGateway(proxy);

        require(impl == predictedImpl, "gateway implementation address mismatch");
        require(impl.codehash == expectedGatewayImplRuntimeCodeHash, "gateway implementation runtime mismatch");
        require(proxy.codehash == expectedGatewayProxyRuntimeCodeHash, "gateway proxy runtime mismatch");
        require(_implementationOf(proxy) == impl, "gateway proxy implementation mismatch");
        require(address(gateway.etherFiDataProvider()) == dataProvider, "gateway data provider mismatch");
        require(address(gateway.spoke()) == spoke, "gateway spoke mismatch");
        require(address(gateway.roleRegistry()) == roleRegistry, "gateway role registry mismatch");
        return (impl, proxy);
    }

    /// @dev Deploys local reference contracts outside broadcast so existing CREATE3 code can be compared exactly.
    function _setExpectedGatewayRuntimeCodeHashes(address dataProvider, address roleRegistry, address spoke) internal {
        LendGateway referenceImpl = new LendGateway(dataProvider, spoke);
        UUPSProxy referenceProxy = new UUPSProxy(address(referenceImpl), abi.encodeWithSelector(LendGateway.initialize.selector, roleRegistry));
        expectedGatewayImplRuntimeCodeHash = address(referenceImpl).codehash;
        expectedGatewayProxyRuntimeCodeHash = address(referenceProxy).codehash;
    }

    /// @dev Stops a rerun when the local gateway bytecode differs from the version recorded by the first run.
    function _requireGatewayCodeVersion(bytes32 implCodeHash, bytes32 proxyCodeHash) internal view {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
        if (!vm.exists(path)) return;

        string memory json = vm.readFile(path);
        require(stdJson.readBytes32(json, ".lendGatewayImplInitCodeHash") == implCodeHash, "LendGateway implementation bytecode changed; bump salt version");
        require(stdJson.readBytes32(json, ".lendGatewayProxyInitCodeHash") == proxyCodeHash, "LendGateway proxy bytecode changed; bump salt version");
        require(stdJson.readBytes32(json, ".lendGatewayImplRuntimeCodeHash") == expectedGatewayImplRuntimeCodeHash, "LendGateway implementation runtime changed; bump salt version");
        require(stdJson.readBytes32(json, ".lendGatewayProxyRuntimeCodeHash") == expectedGatewayProxyRuntimeCodeHash, "LendGateway proxy runtime changed; bump salt version");
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

        // Apply the initial dev policy and enable DebtManager and TopUpDest as known rollout drivers.
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
        bytes32 gatewayImplCodeHash = keccak256(abi.encodePacked(type(LendGateway).creationCode, abi.encode(c.dataProvider, spoke)));
        bytes32 gatewayProxyCodeHash = keccak256(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(gatewayImpl, abi.encodeWithSelector(LendGateway.initialize.selector, c.roleRegistry))));
        vm.serializeBytes32(object, "lendGatewayImplInitCodeHash", gatewayImplCodeHash);
        vm.serializeBytes32(object, "lendGatewayProxyInitCodeHash", gatewayProxyCodeHash);
        vm.serializeBytes32(object, "lendGatewayImplRuntimeCodeHash", expectedGatewayImplRuntimeCodeHash);
        vm.serializeBytes32(object, "lendGatewayProxyRuntimeCodeHash", expectedGatewayProxyRuntimeCodeHash);
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
