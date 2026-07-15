// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title VerifyCashLendDev
 * @notice Verifies the deployment produced by DeployCashLendDev
 * @dev Dev-only and read-only with respect to the target chain. It deploys local reference bytecode during
 *      Forge simulation, but never starts a broadcast. Reverts on the first mismatch.
 *
 * Usage:
 *   source .env && ENV=dev forge script \
 *     scripts/lend/VerifyCashLendDev.s.sol:VerifyCashLendDev \
 *     --rpc-url $OPTIMISM_RPC -vvvv
 */
contract VerifyCashLendDev is Utils {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant GATEWAY_IMPL_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayImpl/v1");
    bytes32 internal constant GATEWAY_PROXY_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayProxy/v1");
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant MIN_HEALTH_FACTOR = 1.05e18;

    struct Deployment {
        address admin;
        address cashEventEmitter;
        address cashEventEmitterImpl;
        address cashLens;
        address cashLensImpl;
        address cashModule;
        address cashModuleCoreImpl;
        address cashModuleSettersImpl;
        address debtManager;
        address debtManagerAdminImpl;
        address debtManagerCoreImpl;
        address deployer;
        address etherFiHook;
        address etherFiHookImpl;
        address lendGateway;
        address lendGatewayImpl;
        bytes32 lendGatewayImplInitCodeHash;
        bytes32 lendGatewayProxyInitCodeHash;
        bytes32 lendGatewayImplRuntimeCodeHash;
        bytes32 lendGatewayProxyRuntimeCodeHash;
        address spoke;
        address topUpDest;
        address topUpDestImpl;
    }

    /// @dev Loads the Cash Lend manifest and runs every post-deployment verification check.
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        Deployment memory d = _readDeployment();
        string memory baseJson = readDeploymentFile();
        string memory aaveJson = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/aave-v4-test.json"));
        address dataProvider = stdJson.readAddress(baseJson, ".addresses.EtherFiDataProvider");
        address roleRegistry = stdJson.readAddress(baseJson, ".addresses.RoleRegistry");
        address usdc = getChainConfig(vm.toString(block.chainid)).usdc;

        _verifyCanonicalAddresses(d, baseJson, aaveJson);
        _verifyCode(d);
        _verifyImplementations(d);
        _verifyGatewayCodeVersion(d, dataProvider, roleRegistry);
        _verifyImmutables(d, dataProvider);
        _verifyGateway(d, roleRegistry, usdc);

        console.log("Cash Lend dev deployment verified");
    }

    /// @dev Reads all deployed proxy and implementation addresses from the Cash Lend manifest.
    function _readDeployment() internal view returns (Deployment memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
        string memory json = vm.readFile(path);
        Deployment memory deployment;

        require(stdJson.readUint(json, ".chainId") == block.chainid, "deployment chain mismatch");
        deployment.admin = stdJson.readAddress(json, ".admin");
        deployment.cashEventEmitter = stdJson.readAddress(json, ".cashEventEmitter");
        deployment.cashEventEmitterImpl = stdJson.readAddress(json, ".cashEventEmitterImpl");
        deployment.cashLens = stdJson.readAddress(json, ".cashLens");
        deployment.cashLensImpl = stdJson.readAddress(json, ".cashLensImpl");
        deployment.cashModule = stdJson.readAddress(json, ".cashModule");
        deployment.cashModuleCoreImpl = stdJson.readAddress(json, ".cashModuleCoreImpl");
        deployment.cashModuleSettersImpl = stdJson.readAddress(json, ".cashModuleSettersImpl");
        deployment.debtManager = stdJson.readAddress(json, ".debtManager");
        deployment.debtManagerAdminImpl = stdJson.readAddress(json, ".debtManagerAdminImpl");
        deployment.debtManagerCoreImpl = stdJson.readAddress(json, ".debtManagerCoreImpl");
        deployment.deployer = stdJson.readAddress(json, ".deployer");
        deployment.etherFiHook = stdJson.readAddress(json, ".etherFiHook");
        deployment.etherFiHookImpl = stdJson.readAddress(json, ".etherFiHookImpl");
        deployment.lendGateway = stdJson.readAddress(json, ".lendGateway");
        deployment.lendGatewayImpl = stdJson.readAddress(json, ".lendGatewayImpl");
        deployment.lendGatewayImplInitCodeHash = stdJson.readBytes32(json, ".lendGatewayImplInitCodeHash");
        deployment.lendGatewayProxyInitCodeHash = stdJson.readBytes32(json, ".lendGatewayProxyInitCodeHash");
        deployment.lendGatewayImplRuntimeCodeHash = stdJson.readBytes32(json, ".lendGatewayImplRuntimeCodeHash");
        deployment.lendGatewayProxyRuntimeCodeHash = stdJson.readBytes32(json, ".lendGatewayProxyRuntimeCodeHash");
        deployment.spoke = stdJson.readAddress(json, ".spoke");
        deployment.topUpDest = stdJson.readAddress(json, ".topUpDest");
        deployment.topUpDestImpl = stdJson.readAddress(json, ".topUpDestImpl");
        return deployment;
    }

    /// @dev Confirms the generated deployment file points to the canonical dev contracts.
    function _verifyCanonicalAddresses(Deployment memory d, string memory baseJson, string memory aaveJson) internal pure {
        require(d.cashEventEmitter == stdJson.readAddress(baseJson, ".addresses.CashEventEmitter"), "non-canonical CashEventEmitter proxy");
        require(d.cashLens == stdJson.readAddress(baseJson, ".addresses.CashLens"), "non-canonical CashLens proxy");
        require(d.cashModule == stdJson.readAddress(baseJson, ".addresses.CashModule"), "non-canonical CashModule proxy");
        require(d.debtManager == stdJson.readAddress(baseJson, ".addresses.DebtManager"), "non-canonical DebtManager proxy");
        require(d.etherFiHook == stdJson.readAddress(baseJson, ".addresses.EtherFiHook"), "non-canonical EtherFiHook proxy");
        require(d.topUpDest == stdJson.readAddress(baseJson, ".addresses.TopUpDest"), "non-canonical TopUpDest proxy");
        require(d.spoke == stdJson.readAddress(aaveJson, ".spoke"), "non-canonical Aave Spoke");
        require(d.admin == stdJson.readAddress(aaveJson, ".admin"), "non-canonical dev admin");
        require(d.lendGatewayImpl == CREATE3.predictDeterministicAddress(GATEWAY_IMPL_SALT, NICKS_FACTORY), "non-canonical LendGateway implementation");
        require(d.lendGateway == CREATE3.predictDeterministicAddress(GATEWAY_PROXY_SALT, NICKS_FACTORY), "non-canonical LendGateway proxy");
    }

    /// @dev Confirms that every expected proxy and implementation address contains bytecode.
    function _verifyCode(Deployment memory d) internal view {
        require(d.cashEventEmitter.code.length != 0 && d.cashEventEmitterImpl.code.length != 0, "CashEventEmitter code missing");
        require(d.cashLens.code.length != 0 && d.cashLensImpl.code.length != 0, "CashLens code missing");
        require(d.cashModule.code.length != 0 && d.cashModuleCoreImpl.code.length != 0 && d.cashModuleSettersImpl.code.length != 0, "CashModule code missing");
        require(d.debtManager.code.length != 0 && d.debtManagerCoreImpl.code.length != 0 && d.debtManagerAdminImpl.code.length != 0, "DebtManager code missing");
        require(d.etherFiHook.code.length != 0 && d.etherFiHookImpl.code.length != 0, "EtherFiHook code missing");
        require(d.lendGateway.code.length != 0 && d.lendGatewayImpl.code.length != 0, "LendGateway code missing");
        require(d.topUpDest.code.length != 0 && d.topUpDestImpl.code.length != 0, "TopUpDest code missing");
    }

    /// @dev Confirms that each proxy and delegated implementation pointer matches the manifest.
    function _verifyImplementations(Deployment memory d) internal view {
        require(_implementationOf(d.cashEventEmitter) == d.cashEventEmitterImpl, "CashEventEmitter implementation mismatch");
        require(_implementationOf(d.cashLens) == d.cashLensImpl, "CashLens implementation mismatch");
        require(_implementationOf(d.cashModule) == d.cashModuleCoreImpl, "CashModule implementation mismatch");
        require(CashModuleCore(d.cashModule).getCashModuleSetters() == d.cashModuleSettersImpl, "CashModule setters mismatch");
        require(_implementationOf(d.debtManager) == d.debtManagerCoreImpl, "DebtManager implementation mismatch");
        require(IDebtManager(d.debtManager).getDebtManagerAdmin() == d.debtManagerAdminImpl, "DebtManager admin mismatch");
        require(_implementationOf(d.etherFiHook) == d.etherFiHookImpl, "EtherFiHook implementation mismatch");
        require(_implementationOf(d.lendGateway) == d.lendGatewayImpl, "LendGateway implementation mismatch");
        require(_implementationOf(d.topUpDest) == d.topUpDestImpl, "TopUpDest implementation mismatch");
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }

    /// @dev Confirms the deterministic gateway uses the same compiled version recorded by deployment.
    function _verifyGatewayCodeVersion(Deployment memory d, address dataProvider, address roleRegistry) internal {
        bytes32 implCodeHash = keccak256(abi.encodePacked(type(LendGateway).creationCode, abi.encode(dataProvider, d.spoke)));
        bytes32 proxyCodeHash = keccak256(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(d.lendGatewayImpl, abi.encodeWithSelector(LendGateway.initialize.selector, roleRegistry))));
        require(d.lendGatewayImplInitCodeHash == implCodeHash, "LendGateway implementation bytecode mismatch");
        require(d.lendGatewayProxyInitCodeHash == proxyCodeHash, "LendGateway proxy bytecode mismatch");

        LendGateway referenceImpl = new LendGateway(dataProvider, d.spoke);
        UUPSProxy referenceProxy = new UUPSProxy(address(referenceImpl), abi.encodeWithSelector(LendGateway.initialize.selector, roleRegistry));
        bytes32 implRuntimeHash = address(referenceImpl).codehash;
        bytes32 proxyRuntimeHash = address(referenceProxy).codehash;
        require(d.lendGatewayImplRuntimeCodeHash == implRuntimeHash && d.lendGatewayImpl.codehash == implRuntimeHash, "LendGateway implementation runtime mismatch");
        require(d.lendGatewayProxyRuntimeCodeHash == proxyRuntimeHash && d.lendGateway.codehash == proxyRuntimeHash, "LendGateway proxy runtime mismatch");
    }

    /// @dev Confirms constructor-set references on upgraded implementations still point to dev dependencies.
    function _verifyImmutables(Deployment memory d, address dataProvider) internal view {
        require(address(CashModuleCore(d.cashModule).etherFiDataProvider()) == dataProvider, "CashModule core dataProvider mismatch");
        require(address(CashModuleSetters(d.cashModuleSettersImpl).etherFiDataProvider()) == dataProvider, "CashModule setters dataProvider mismatch");
        require(address(CashLens(d.cashLens).cashModule()) == d.cashModule, "CashLens cashModule mismatch");
        require(address(CashLens(d.cashLens).dataProvider()) == dataProvider, "CashLens dataProvider mismatch");
        require(CashEventEmitter(d.cashEventEmitter).cashModule() == d.cashModule, "CashEventEmitter cashModule mismatch");
        require(address(DebtManagerCore(d.debtManager).etherFiDataProvider()) == dataProvider, "DebtManager core dataProvider mismatch");
        require(address(DebtManagerAdmin(d.debtManagerAdminImpl).etherFiDataProvider()) == dataProvider, "DebtManager admin dataProvider mismatch");
        require(address(EtherFiHook(d.etherFiHook).dataProvider()) == dataProvider, "EtherFiHook dataProvider mismatch");
        require(address(TopUpDest(payable(d.topUpDest)).etherFiDataProvider()) == dataProvider, "TopUpDest dataProvider mismatch");
        require(address(TopUpDest(payable(d.topUpDest)).weth()) == getChainConfig(vm.toString(block.chainid)).weth, "TopUpDest WETH mismatch");
    }

    /// @dev Confirms gateway roles, policy, reserve mappings, drivers, and Aave position-manager activation.
    function _verifyGateway(Deployment memory d, address roleRegistry, address usdc) internal view {
        LendGateway gateway = LendGateway(d.lendGateway);
        IAaveV4Spoke spoke = IAaveV4Spoke(d.spoke);

        require(address(gateway.etherFiDataProvider()) == address(CashLens(d.cashLens).dataProvider()), "gateway dataProvider mismatch");
        require(address(gateway.spoke()) == d.spoke, "gateway Spoke mismatch");
        require(address(gateway.roleRegistry()) == roleRegistry, "gateway role registry mismatch");
        require(address(ICashModule(d.cashModule).getLendGateway()) == d.lendGateway, "CashModule gateway mismatch");
        require(gateway.minHealthFactor() == MIN_HEALTH_FACTOR, "minimum health factor mismatch");
        require(gateway.isSpendAsset(usdc), "USDC not spendable");
        require(gateway.isDriver(d.debtManager), "DebtManager not a driver");
        require(gateway.isDriver(d.topUpDest), "TopUpDest not a driver");
        require(spoke.isPositionManagerActive(d.lendGateway), "gateway not active on Spoke");
        require(d.deployer == d.admin, "deployer is not dev admin");
        require(RoleRegistry(roleRegistry).owner() == d.admin, "dev admin mismatch");
        require(RoleRegistry(roleRegistry).hasRole(gateway.LEND_GATEWAY_ADMIN_ROLE(), d.admin), "gateway admin role missing");

        uint256 count = spoke.getReserveCount();
        require(gateway.registeredAssets().length == count, "registered reserve count mismatch");
        for (uint256 reserveId = 0; reserveId < count; ++reserveId) {
            address asset = spoke.getReserve(reserveId).underlying;
            require(gateway.isRegistered(asset), "reserve asset not registered");
            require(gateway.reserveIdOf(asset) == reserveId, "reserve ID mismatch");
        }
    }
}
