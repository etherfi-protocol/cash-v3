// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
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
 * @title VerifyCashLendRollbackDev
 * @notice Verifies the implementation rollback produced by RollbackCashLendDev
 * @dev Read-only and dev-only. It confirms the original implementations, unchanged tracked gateway
 *      state, and unchanged stable Aave position storage for every snapshotted pilot Safe.
 *
 * Usage:
 *   source .env && ENV=dev forge script \
 *     scripts/lend/VerifyCashLendRollbackDev.s.sol:VerifyCashLendRollbackDev \
 *     --rpc-url $OPTIMISM_RPC -vvvv
 */
contract VerifyCashLendRollbackDev is Utils {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant GATEWAY_IMPL_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayImpl/v1");
    bytes32 internal constant GATEWAY_PROXY_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayProxy/v1");
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Deployment {
        address cashEventEmitter;
        address cashLens;
        address cashModule;
        address debtManager;
        address etherFiHook;
        address lendGateway;
        address lendGatewayImpl;
        bytes32 lendGatewayImplRuntimeCodeHash;
        bytes32 lendGatewayProxyRuntimeCodeHash;
        address previousCashEventEmitterImpl;
        address previousCashLensImpl;
        address previousCashModuleCoreImpl;
        address previousCashModuleSettersImpl;
        address previousDebtManagerAdminImpl;
        address previousDebtManagerCoreImpl;
        address previousEtherFiHookImpl;
        address previousTopUpDestImpl;
        address spoke;
        address topUpDest;
    }

    struct Snapshot {
        bytes32 trackedGatewayStateHash;
        address lendGateway;
        address[] pilotSafes;
        bytes32[] positionHashes;
        address spoke;
    }

    /// @dev Loads deployment and snapshot artifacts, then checks the actual post-broadcast chain state.
    function run() public view {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        Deployment memory deployment = _readDeployment();
        Snapshot memory snapshot = _readSnapshot();
        require(snapshot.lendGateway == deployment.lendGateway, "snapshot gateway mismatch");
        require(snapshot.spoke == deployment.spoke, "snapshot Spoke mismatch");

        LendGateway gateway = LendGateway(deployment.lendGateway);
        IAaveV4Spoke spoke = IAaveV4Spoke(deployment.spoke);

        _requireOriginalImplementations(deployment);
        _requireOriginalImmutables(deployment);
        require(_implementationOf(deployment.lendGateway) == deployment.lendGatewayImpl, "LendGateway implementation changed");
        require(deployment.lendGatewayImpl.codehash == deployment.lendGatewayImplRuntimeCodeHash, "LendGateway implementation runtime changed");
        require(deployment.lendGateway.codehash == deployment.lendGatewayProxyRuntimeCodeHash, "LendGateway proxy runtime changed");
        require(_trackedGatewayStateHash(deployment, gateway, spoke) == snapshot.trackedGatewayStateHash, "tracked gateway state changed");
        _requirePositionHashes(spoke, snapshot.pilotSafes, snapshot.positionHashes);

        console.log("Cash Lend dev rollback verified");
    }

    /// @dev Loads the proxies and original implementation references from the Cash Lend deployment manifest.
    function _readDeployment() internal view returns (Deployment memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
        string memory json = vm.readFile(path);
        Deployment memory deployment;

        require(stdJson.readUint(json, ".chainId") == block.chainid, "deployment chain mismatch");
        deployment.cashEventEmitter = stdJson.readAddress(json, ".cashEventEmitter");
        deployment.cashLens = stdJson.readAddress(json, ".cashLens");
        deployment.cashModule = stdJson.readAddress(json, ".cashModule");
        deployment.debtManager = stdJson.readAddress(json, ".debtManager");
        deployment.etherFiHook = stdJson.readAddress(json, ".etherFiHook");
        deployment.lendGateway = stdJson.readAddress(json, ".lendGateway");
        deployment.lendGatewayImpl = stdJson.readAddress(json, ".lendGatewayImpl");
        deployment.lendGatewayImplRuntimeCodeHash = stdJson.readBytes32(json, ".lendGatewayImplRuntimeCodeHash");
        deployment.lendGatewayProxyRuntimeCodeHash = stdJson.readBytes32(json, ".lendGatewayProxyRuntimeCodeHash");
        deployment.previousCashEventEmitterImpl = stdJson.readAddress(json, ".previousCashEventEmitterImpl");
        deployment.previousCashLensImpl = stdJson.readAddress(json, ".previousCashLensImpl");
        deployment.previousCashModuleCoreImpl = stdJson.readAddress(json, ".previousCashModuleCoreImpl");
        deployment.previousCashModuleSettersImpl = stdJson.readAddress(json, ".previousCashModuleSettersImpl");
        deployment.previousDebtManagerAdminImpl = stdJson.readAddress(json, ".previousDebtManagerAdminImpl");
        deployment.previousDebtManagerCoreImpl = stdJson.readAddress(json, ".previousDebtManagerCoreImpl");
        deployment.previousEtherFiHookImpl = stdJson.readAddress(json, ".previousEtherFiHookImpl");
        deployment.previousTopUpDestImpl = stdJson.readAddress(json, ".previousTopUpDestImpl");
        deployment.spoke = stdJson.readAddress(json, ".spoke");
        deployment.topUpDest = stdJson.readAddress(json, ".topUpDest");
        _requireCanonicalAddresses(deployment);
        return deployment;
    }

    /// @dev Confirms the deployment file points to the canonical dev proxies, gateway, and Aave Spoke.
    function _requireCanonicalAddresses(Deployment memory deployment) internal view {
        string memory baseJson = readDeploymentFile();
        require(deployment.cashEventEmitter == stdJson.readAddress(baseJson, ".addresses.CashEventEmitter"), "non-canonical CashEventEmitter proxy");
        require(deployment.cashLens == stdJson.readAddress(baseJson, ".addresses.CashLens"), "non-canonical CashLens proxy");
        require(deployment.cashModule == stdJson.readAddress(baseJson, ".addresses.CashModule"), "non-canonical CashModule proxy");
        require(deployment.debtManager == stdJson.readAddress(baseJson, ".addresses.DebtManager"), "non-canonical DebtManager proxy");
        require(deployment.etherFiHook == stdJson.readAddress(baseJson, ".addresses.EtherFiHook"), "non-canonical EtherFiHook proxy");
        require(deployment.topUpDest == stdJson.readAddress(baseJson, ".addresses.TopUpDest"), "non-canonical TopUpDest proxy");

        string memory aaveJson = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/aave-v4-test.json"));
        require(deployment.spoke == stdJson.readAddress(aaveJson, ".spoke"), "non-canonical Aave Spoke");
        address roleRegistry = stdJson.readAddress(baseJson, ".addresses.RoleRegistry");
        require(RoleRegistry(roleRegistry).owner() == stdJson.readAddress(aaveJson, ".admin"), "Cash and Aave dev admins differ");
        require(deployment.lendGatewayImpl == CREATE3.predictDeterministicAddress(GATEWAY_IMPL_SALT, NICKS_FACTORY), "non-canonical LendGateway implementation");
        require(deployment.lendGateway == CREATE3.predictDeterministicAddress(GATEWAY_PROXY_SALT, NICKS_FACTORY), "non-canonical LendGateway proxy");
        require(address(LendGateway(deployment.lendGateway).roleRegistry()) == stdJson.readAddress(baseJson, ".addresses.RoleRegistry"), "non-canonical gateway RoleRegistry");

        string memory baseline = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend-rollback-baseline.json"));
        require(stdJson.readUint(baseline, ".chainId") == block.chainid, "rollback file chain mismatch");
        require(deployment.previousCashEventEmitterImpl == stdJson.readAddress(baseline, ".cashEventEmitterImpl"), "non-canonical previous CashEventEmitter");
        require(deployment.previousCashLensImpl == stdJson.readAddress(baseline, ".cashLensImpl"), "non-canonical previous CashLens");
        require(deployment.previousCashModuleCoreImpl == stdJson.readAddress(baseline, ".cashModuleCoreImpl"), "non-canonical previous CashModule core");
        require(deployment.previousCashModuleSettersImpl == stdJson.readAddress(baseline, ".cashModuleSettersImpl"), "non-canonical previous CashModule setters");
        require(deployment.previousDebtManagerCoreImpl == stdJson.readAddress(baseline, ".debtManagerCoreImpl"), "non-canonical previous DebtManager core");
        require(deployment.previousDebtManagerAdminImpl == stdJson.readAddress(baseline, ".debtManagerAdminImpl"), "non-canonical previous DebtManager admin");
        require(deployment.previousEtherFiHookImpl == stdJson.readAddress(baseline, ".etherFiHookImpl"), "non-canonical previous EtherFiHook");
        require(deployment.previousTopUpDestImpl == stdJson.readAddress(baseline, ".topUpDestImpl"), "non-canonical previous TopUpDest");
        require(deployment.previousCashEventEmitterImpl.codehash == stdJson.readBytes32(baseline, ".cashEventEmitterCodeHash"), "previous CashEventEmitter code changed");
        require(deployment.previousCashLensImpl.codehash == stdJson.readBytes32(baseline, ".cashLensCodeHash"), "previous CashLens code changed");
        require(deployment.previousCashModuleCoreImpl.codehash == stdJson.readBytes32(baseline, ".cashModuleCoreCodeHash"), "previous CashModule core code changed");
        require(deployment.previousCashModuleSettersImpl.codehash == stdJson.readBytes32(baseline, ".cashModuleSettersCodeHash"), "previous CashModule setters code changed");
        require(deployment.previousDebtManagerCoreImpl.codehash == stdJson.readBytes32(baseline, ".debtManagerCoreCodeHash"), "previous DebtManager core code changed");
        require(deployment.previousDebtManagerAdminImpl.codehash == stdJson.readBytes32(baseline, ".debtManagerAdminCodeHash"), "previous DebtManager admin code changed");
        require(deployment.previousEtherFiHookImpl.codehash == stdJson.readBytes32(baseline, ".etherFiHookCodeHash"), "previous EtherFiHook code changed");
        require(deployment.previousTopUpDestImpl.codehash == stdJson.readBytes32(baseline, ".topUpDestCodeHash"), "previous TopUpDest code changed");
    }

    /// @dev Loads the gateway and pilot position hashes captured immediately before rollback.
    function _readSnapshot() internal view returns (Snapshot memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend-rollback.json");
        string memory json = vm.readFile(path);
        Snapshot memory snapshot;

        require(stdJson.readUint(json, ".chainId") == block.chainid, "snapshot chain mismatch");
        snapshot.trackedGatewayStateHash = stdJson.readBytes32(json, ".trackedGatewayStateHash");
        snapshot.lendGateway = stdJson.readAddress(json, ".lendGateway");
        snapshot.pilotSafes = stdJson.readAddressArray(json, ".pilotSafes");
        snapshot.positionHashes = stdJson.readBytes32Array(json, ".positionHashes");
        snapshot.spoke = stdJson.readAddress(json, ".spoke");
        return snapshot;
    }

    /// @dev Confirms every rolled-back proxy and delegated pointer references its recorded original implementation.
    function _requireOriginalImplementations(Deployment memory deployment) internal view {
        require(_implementationOf(deployment.cashEventEmitter) == deployment.previousCashEventEmitterImpl, "CashEventEmitter rollback mismatch");
        require(_implementationOf(deployment.cashLens) == deployment.previousCashLensImpl, "CashLens rollback mismatch");
        require(_implementationOf(deployment.cashModule) == deployment.previousCashModuleCoreImpl, "CashModule rollback mismatch");
        require(CashModuleCore(deployment.cashModule).getCashModuleSetters() == deployment.previousCashModuleSettersImpl, "CashModule setters rollback mismatch");
        require(_implementationOf(deployment.debtManager) == deployment.previousDebtManagerCoreImpl, "DebtManager rollback mismatch");
        require(IDebtManager(deployment.debtManager).getDebtManagerAdmin() == deployment.previousDebtManagerAdminImpl, "DebtManager admin rollback mismatch");
        require(_implementationOf(deployment.etherFiHook) == deployment.previousEtherFiHookImpl, "EtherFiHook rollback mismatch");
        require(_implementationOf(deployment.topUpDest) == deployment.previousTopUpDestImpl, "TopUpDest rollback mismatch");
    }

    /// @dev Confirms the restored implementations were built for the canonical Cash proxies and dev dependencies.
    function _requireOriginalImmutables(Deployment memory deployment) internal view {
        string memory baseJson = readDeploymentFile();
        address dataProvider = stdJson.readAddress(baseJson, ".addresses.EtherFiDataProvider");
        address weth = getChainConfig(vm.toString(block.chainid)).weth;

        require(CashEventEmitter(deployment.previousCashEventEmitterImpl).cashModule() == deployment.cashModule, "previous CashEventEmitter cashModule mismatch");
        require(address(CashLens(deployment.previousCashLensImpl).cashModule()) == deployment.cashModule, "previous CashLens cashModule mismatch");
        require(address(CashLens(deployment.previousCashLensImpl).dataProvider()) == dataProvider, "previous CashLens dataProvider mismatch");
        require(address(CashModuleCore(deployment.previousCashModuleCoreImpl).etherFiDataProvider()) == dataProvider, "previous CashModule core dataProvider mismatch");
        require(address(CashModuleSetters(deployment.previousCashModuleSettersImpl).etherFiDataProvider()) == dataProvider, "previous CashModule setters dataProvider mismatch");
        require(address(DebtManagerCore(deployment.previousDebtManagerCoreImpl).etherFiDataProvider()) == dataProvider, "previous DebtManager core dataProvider mismatch");
        require(address(DebtManagerAdmin(deployment.previousDebtManagerAdminImpl).etherFiDataProvider()) == dataProvider, "previous DebtManager admin dataProvider mismatch");
        require(address(EtherFiHook(deployment.previousEtherFiHookImpl).dataProvider()) == dataProvider, "previous EtherFiHook dataProvider mismatch");
        require(address(TopUpDest(payable(deployment.previousTopUpDestImpl)).etherFiDataProvider()) == dataProvider, "previous TopUpDest dataProvider mismatch");
        require(address(TopUpDest(payable(deployment.previousTopUpDestImpl)).weth()) == weth, "previous TopUpDest WETH mismatch");
    }

    /// @dev Hashes the enumerable gateway policy, known drivers, pause state, and Aave activation tracked by this rollout.
    function _trackedGatewayStateHash(Deployment memory deployment, LendGateway gateway, IAaveV4Spoke spoke) internal view returns (bytes32) {
        address[] memory assets = gateway.registeredAssets();
        address[] memory spendAssets = gateway.spendAssets();
        bytes32 hash = keccak256(abi.encode(_implementationOf(deployment.lendGateway), address(gateway.roleRegistry()), gateway.roleRegistry().owner(), gateway.paused(), gateway.minHealthFactor(), gateway.isDriver(deployment.debtManager), gateway.isDriver(deployment.topUpDest), spoke.isPositionManagerActive(deployment.lendGateway), assets, spendAssets));

        for (uint256 i = 0; i < assets.length; ++i) {
            hash = keccak256(abi.encode(hash, assets[i], gateway.reserveIdOf(assets[i])));
        }
        return hash;
    }

    /// @dev Confirms every snapshotted Safe still has exactly the same stable Aave position storage.
    function _requirePositionHashes(IAaveV4Spoke spoke, address[] memory pilotSafes, bytes32[] memory expectedHashes) internal view {
        require(pilotSafes.length == expectedHashes.length, "position snapshot length mismatch");
        for (uint256 i = 0; i < pilotSafes.length; ++i) {
            require(_positionHash(spoke, pilotSafes[i]) == expectedHashes[i], "Aave pilot position changed");
        }
    }

    /// @dev Hashes raw Aave user-position storage across every reserve so interest accrual cannot cause false failures.
    function _positionHash(IAaveV4Spoke spoke, address safe) internal view returns (bytes32) {
        uint256 reserveCount = spoke.getReserveCount();
        bytes32 hash = keccak256(abi.encode(safe, reserveCount));

        for (uint256 reserveId = 0; reserveId < reserveCount; ++reserveId) {
            (bool success, bytes memory position) = address(spoke).staticcall(abi.encodeWithSignature("getUserPosition(uint256,address)", reserveId, safe));
            require(success, "Aave position read failed");
            (bool usingAsCollateral, bool borrowed) = spoke.getUserReserveStatus(reserveId, safe);
            hash = keccak256(abi.encode(hash, reserveId, position, usingAsCollateral, borrowed));
        }

        return hash;
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }
}
