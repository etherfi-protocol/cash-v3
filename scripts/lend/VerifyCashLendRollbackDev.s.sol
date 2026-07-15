// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
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
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Deployment {
        address cashEventEmitter;
        address cashLens;
        address cashModule;
        address debtManager;
        address etherFiHook;
        address lendGateway;
        address lendGatewayImpl;
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
        require(_implementationOf(deployment.lendGateway) == deployment.lendGatewayImpl, "LendGateway implementation changed");
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
        return deployment;
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

    /// @dev Hashes the enumerable gateway policy, known drivers, pause state, and Aave activation tracked by this rollout.
    function _trackedGatewayStateHash(Deployment memory deployment, LendGateway gateway, IAaveV4Spoke spoke) internal view returns (bytes32) {
        address[] memory assets = gateway.registeredAssets();
        address[] memory spendAssets = gateway.spendAssets();
        bytes32 hash = keccak256(abi.encode(_implementationOf(deployment.lendGateway), address(gateway.roleRegistry()), gateway.paused(), gateway.minHealthFactor(), gateway.isDriver(deployment.debtManager), gateway.isDriver(deployment.topUpDest), spoke.isPositionManagerActive(deployment.lendGateway), assets, spendAssets));

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
            hash = keccak256(abi.encode(hash, reserveId, position));
        }

        return hash;
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }
}
