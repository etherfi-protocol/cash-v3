// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IAaveV4Oracle } from "../../src/interfaces/IAaveV4Oracle.sol";
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
 * @title RollbackCashLendDev
 * @notice Restores the implementations that preceded the Optimism dev Cash Lend deployment
 * @dev Test-only implementation rollback. It never repays, withdraws, or changes LendGateway/Aave
 *      configuration. `clean-only` stops on known pilot positions or aggregate Spoke supply/debt over $100.
 *      `force-implementations` logs those conditions and restores the implementations anyway. If the Aave
 *      oracle cannot be read, both modes stop. Clean-only checks are a preflight, not an atomic on-chain guard:
 *      each reference change is a separate EOA transaction. If broadcasting stops partway, rerun this script
 *      to skip restored references and resume, then run VerifyCashLendRollbackDev against the final chain state.
 *
 * Usage:
 *   source .env && ENV=dev TEST_ROLLBACK=true ROLLBACK_MODE=clean-only \
 *     LEND_PILOT_SAFES=0xSafe1,0xSafe2 forge script \
 *     scripts/lend/RollbackCashLendDev.s.sol:RollbackCashLendDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 *
 * `LEND_PILOT_SAFES` is optional. When omitted, per-Safe checks are skipped and the aggregate
 * Spoke checks remain in force. Use ROLLBACK_MODE=force-implementations for the explicit alternative.
 */
contract RollbackCashLendDev is Utils {
    using Math for uint256;

    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant GATEWAY_IMPL_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayImpl/v1");
    bytes32 internal constant GATEWAY_PROXY_SALT = keccak256("ether.fi/cash-lend/dev/LendGatewayProxy/v1");
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant ORACLE_USD_SCALE = 1e8;
    uint256 internal constant MAX_SPOKE_SUPPLY_USD = 100 * ORACLE_USD_SCALE;
    uint256 internal constant MAX_SPOKE_DEBT_USD = 100 * ORACLE_USD_SCALE;

    enum RollbackMode {
        CleanOnly,
        ForceImplementations
    }

    struct Deployment {
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
        address etherFiHook;
        address etherFiHookImpl;
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
        address topUpDestImpl;
    }

    /// @dev Validates rollback intent, snapshots Lend state, restores implementations, and proves Lend state did not change.
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");
        require(vm.envOr("TEST_ROLLBACK", false), "TEST_ROLLBACK must be true");

        RollbackMode mode = _rollbackMode(vm.envOr("ROLLBACK_MODE", string("clean-only")));
        address[] memory pilotSafes = vm.envOr("LEND_PILOT_SAFES", ",", new address[](0));
        Deployment memory deployment = _readDeployment();
        IAaveV4Spoke spoke = IAaveV4Spoke(deployment.spoke);
        LendGateway gateway = LendGateway(deployment.lendGateway);

        _validateDevAdmin(deployment.cashModule, tx.origin);
        _validatePilotSafes(pilotSafes);
        _requireExpectedImplementations(deployment);

        // Inspect explicitly supplied pilot Safes and retain stable Aave position hashes for post-rollback checks.
        (bool hasNonCleanSafe, bytes32[] memory positionHashes) = _inspectPilotSafes(deployment.cashModule, spoke, pilotSafes);

        // Value the entire Spoke so an omitted pilot list cannot hide material market usage.
        (uint256 supplyUsd, uint256 debtUsd) = _spokeTotalsUsd(spoke);
        _logSpokeTotals(supplyUsd, debtUsd);
        _enforceMode(mode, hasNonCleanSafe, supplyUsd, debtUsd);

        bytes32 trackedGatewayStateHash = _trackedGatewayStateHash(deployment, gateway, spoke);

        vm.startBroadcast();
        _restoreOriginalImplementations(deployment);
        vm.stopBroadcast();

        // Prove the simulated rollback changed only the implementation references described by the manifest.
        _requireOriginalImplementations(deployment);
        require(_trackedGatewayStateHash(deployment, gateway, spoke) == trackedGatewayStateHash, "tracked gateway state changed");
        _requirePositionHashesUnchanged(spoke, pilotSafes, positionHashes);

        _writeRollbackSnapshot(deployment, mode, pilotSafes, positionHashes, trackedGatewayStateHash, supplyUsd, debtUsd);
        console.log("Cash Lend dev implementation rollback simulated successfully");
    }

    /// @dev Parses the only two supported rollback modes and rejects ambiguous values.
    function _rollbackMode(string memory value) internal pure returns (RollbackMode) {
        if (keccak256(bytes(value)) == keccak256(bytes("clean-only"))) return RollbackMode.CleanOnly;
        if (keccak256(bytes(value)) == keccak256(bytes("force-implementations"))) return RollbackMode.ForceImplementations;
        revert("invalid ROLLBACK_MODE");
    }

    /// @dev Confirms the CLI sender is the existing Cash and Aave dev administrator.
    function _validateDevAdmin(address cashModule, address sender) internal view {
        string memory baseJson = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(baseJson, ".addresses.RoleRegistry");
        address admin = RoleRegistry(roleRegistry).owner();
        require(sender == admin, "sender is not Cash dev admin");
        require(RoleRegistry(roleRegistry).hasRole(ICashModule(cashModule).CASH_MODULE_CONTROLLER_ROLE(), sender), "dev admin missing CashModule controller role");

        string memory aaveJson = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/aave-v4-test.json"));
        require(stdJson.readAddress(aaveJson, ".admin") == admin, "Cash and Aave dev admins differ");
    }

    /// @dev Rejects zero, duplicate, or non-contract pilot entries while allowing the list itself to be empty.
    function _validatePilotSafes(address[] memory pilotSafes) internal view {
        for (uint256 i = 0; i < pilotSafes.length; ++i) {
            require(pilotSafes[i] != address(0) && pilotSafes[i].code.length != 0, "invalid pilot Safe");
            for (uint256 j = 0; j < i; ++j) {
                require(pilotSafes[i] != pilotSafes[j], "duplicate pilot Safe");
            }
        }
    }

    /// @dev Loads the new and previous implementation references recorded by DeployCashLendDev.
    function _readDeployment() internal view returns (Deployment memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json");
        string memory json = vm.readFile(path);
        Deployment memory deployment;

        require(stdJson.readUint(json, ".chainId") == block.chainid, "deployment chain mismatch");
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
        deployment.etherFiHook = stdJson.readAddress(json, ".etherFiHook");
        deployment.etherFiHookImpl = stdJson.readAddress(json, ".etherFiHookImpl");
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
        deployment.topUpDestImpl = stdJson.readAddress(json, ".topUpDestImpl");
        _requireCanonicalAddresses(deployment);
        return deployment;
    }

    /// @dev Confirms the editable rollback file points to the canonical dev proxies, gateway, and Aave Spoke.
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
        require(deployment.lendGatewayImpl == CREATE3.predictDeterministicAddress(GATEWAY_IMPL_SALT, NICKS_FACTORY), "non-canonical LendGateway implementation");
        require(deployment.lendGateway == CREATE3.predictDeterministicAddress(GATEWAY_PROXY_SALT, NICKS_FACTORY), "non-canonical LendGateway proxy");
        require(deployment.lendGatewayImpl.code.length != 0 && deployment.lendGateway.code.length != 0, "LendGateway code missing");
        require(_implementationOf(deployment.lendGateway) == deployment.lendGatewayImpl, "LendGateway implementation mismatch");
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
        _requireRollbackCodeHashes(deployment, baseline);
    }

    /// @dev Confirms the canonical rollback targets still have the reviewed runtime code.
    function _requireRollbackCodeHashes(Deployment memory deployment, string memory baseline) internal view {
        require(deployment.previousCashEventEmitterImpl.codehash == stdJson.readBytes32(baseline, ".cashEventEmitterCodeHash"), "previous CashEventEmitter code changed");
        require(deployment.previousCashLensImpl.codehash == stdJson.readBytes32(baseline, ".cashLensCodeHash"), "previous CashLens code changed");
        require(deployment.previousCashModuleCoreImpl.codehash == stdJson.readBytes32(baseline, ".cashModuleCoreCodeHash"), "previous CashModule core code changed");
        require(deployment.previousCashModuleSettersImpl.codehash == stdJson.readBytes32(baseline, ".cashModuleSettersCodeHash"), "previous CashModule setters code changed");
        require(deployment.previousDebtManagerCoreImpl.codehash == stdJson.readBytes32(baseline, ".debtManagerCoreCodeHash"), "previous DebtManager core code changed");
        require(deployment.previousDebtManagerAdminImpl.codehash == stdJson.readBytes32(baseline, ".debtManagerAdminCodeHash"), "previous DebtManager admin code changed");
        require(deployment.previousEtherFiHookImpl.codehash == stdJson.readBytes32(baseline, ".etherFiHookCodeHash"), "previous EtherFiHook code changed");
        require(deployment.previousTopUpDestImpl.codehash == stdJson.readBytes32(baseline, ".topUpDestCodeHash"), "previous TopUpDest code changed");
    }

    /// @dev Requires the live deployment to still be the exact Lend version this deployment file knows how to undo.
    function _requireExpectedImplementations(Deployment memory deployment) internal view {
        // Every rollback target must still exist before the first broadcast transaction is sent.
        require(deployment.previousCashEventEmitterImpl.code.length != 0, "previous CashEventEmitter code missing");
        require(deployment.previousCashLensImpl.code.length != 0, "previous CashLens code missing");
        require(deployment.previousCashModuleCoreImpl.code.length != 0, "previous CashModule core code missing");
        require(deployment.previousCashModuleSettersImpl.code.length != 0, "previous CashModule setters code missing");
        require(deployment.previousDebtManagerAdminImpl.code.length != 0, "previous DebtManager admin code missing");
        require(deployment.previousDebtManagerCoreImpl.code.length != 0, "previous DebtManager core code missing");
        require(deployment.previousEtherFiHookImpl.code.length != 0, "previous EtherFiHook code missing");
        require(deployment.previousTopUpDestImpl.code.length != 0, "previous TopUpDest code missing");

        _requireUUPSImplementation(deployment.previousCashEventEmitterImpl);
        _requireUUPSImplementation(deployment.previousCashLensImpl);
        _requireUUPSImplementation(deployment.previousCashModuleCoreImpl);
        _requireUUPSImplementation(deployment.previousDebtManagerCoreImpl);
        _requireUUPSImplementation(deployment.previousEtherFiHookImpl);
        _requireUUPSImplementation(deployment.previousTopUpDestImpl);
        _requireRollbackTargetImmutables(deployment);

        _requireRollbackReference(_implementationOf(deployment.cashEventEmitter), deployment.cashEventEmitterImpl, deployment.previousCashEventEmitterImpl);
        _requireRollbackReference(_implementationOf(deployment.cashLens), deployment.cashLensImpl, deployment.previousCashLensImpl);
        _requireRollbackReference(_implementationOf(deployment.cashModule), deployment.cashModuleCoreImpl, deployment.previousCashModuleCoreImpl);
        _requireRollbackReference(CashModuleCore(deployment.cashModule).getCashModuleSetters(), deployment.cashModuleSettersImpl, deployment.previousCashModuleSettersImpl);
        _requireRollbackReference(_implementationOf(deployment.debtManager), deployment.debtManagerCoreImpl, deployment.previousDebtManagerCoreImpl);
        _requireRollbackReference(IDebtManager(deployment.debtManager).getDebtManagerAdmin(), deployment.debtManagerAdminImpl, deployment.previousDebtManagerAdminImpl);
        _requireRollbackReference(_implementationOf(deployment.etherFiHook), deployment.etherFiHookImpl, deployment.previousEtherFiHookImpl);
        _requireRollbackReference(_implementationOf(deployment.topUpDest), deployment.topUpDestImpl, deployment.previousTopUpDestImpl);
        require(_implementationOf(deployment.lendGateway) == deployment.lendGatewayImpl, "LendGateway changed since deployment");
    }

    /// @dev Restores only the eight original implementation references; it deliberately makes no LendGateway or Aave call.
    function _restoreOriginalImplementations(Deployment memory deployment) internal {
        // Roll back in reverse deployment order, keep pointer/core pairs adjacent, and skip completed resume steps.
        if (_implementationOf(deployment.topUpDest) != deployment.previousTopUpDestImpl) {
            UUPSUpgradeable(deployment.topUpDest).upgradeToAndCall(deployment.previousTopUpDestImpl, "");
        }
        if (_implementationOf(deployment.etherFiHook) != deployment.previousEtherFiHookImpl) {
            UUPSUpgradeable(deployment.etherFiHook).upgradeToAndCall(deployment.previousEtherFiHookImpl, "");
        }

        if (IDebtManager(deployment.debtManager).getDebtManagerAdmin() != deployment.previousDebtManagerAdminImpl) {
            IDebtManager(deployment.debtManager).setAdminImpl(deployment.previousDebtManagerAdminImpl);
        }
        if (_implementationOf(deployment.debtManager) != deployment.previousDebtManagerCoreImpl) {
            UUPSUpgradeable(deployment.debtManager).upgradeToAndCall(deployment.previousDebtManagerCoreImpl, "");
        }

        if (_implementationOf(deployment.cashEventEmitter) != deployment.previousCashEventEmitterImpl) {
            UUPSUpgradeable(deployment.cashEventEmitter).upgradeToAndCall(deployment.previousCashEventEmitterImpl, "");
        }
        if (_implementationOf(deployment.cashLens) != deployment.previousCashLensImpl) {
            UUPSUpgradeable(deployment.cashLens).upgradeToAndCall(deployment.previousCashLensImpl, "");
        }

        if (CashModuleCore(deployment.cashModule).getCashModuleSetters() != deployment.previousCashModuleSettersImpl) {
            ICashModule(deployment.cashModule).setCashModuleSettersAddress(deployment.previousCashModuleSettersImpl);
        }
        if (_implementationOf(deployment.cashModule) != deployment.previousCashModuleCoreImpl) {
            UUPSUpgradeable(deployment.cashModule).upgradeToAndCall(deployment.previousCashModuleCoreImpl, "");
        }
    }

    /// @dev Allows a fresh rollback or a resumable partially completed rollback, but rejects every unknown version.
    function _requireRollbackReference(address current, address lend, address original) internal pure {
        require(current == lend || current == original, "implementation is outside rollback transition");
    }

    /// @dev Confirms a rollback target advertises the standard ERC-1822 implementation slot.
    function _requireUUPSImplementation(address implementation) internal view {
        (bool success, bytes memory result) = implementation.staticcall(abi.encodeWithSelector(UUPSUpgradeable.proxiableUUID.selector));
        require(success && result.length == 32 && abi.decode(result, (bytes32)) == EIP1967_IMPLEMENTATION_SLOT, "invalid previous UUPS implementation");
    }

    /// @dev Confirms every rollback target was built for the canonical Cash proxies and dev dependencies.
    function _requireRollbackTargetImmutables(Deployment memory deployment) internal view {
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

    /// @dev Confirms every proxy and delegated pointer now references the recorded original implementation.
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

    /// @dev Logs each selected Safe's positions across every Spoke reserve and returns whether any position remains.
    function _inspectPilotSafes(address cashModule, IAaveV4Spoke spoke, address[] memory pilotSafes) internal view returns (bool, bytes32[] memory) {
        uint256 reserveCount = spoke.getReserveCount();
        bytes32[] memory positionHashes = new bytes32[](pilotSafes.length);
        bool hasNonCleanSafe;

        for (uint256 i = 0; i < pilotSafes.length; ++i) {
            address safe = pilotSafes[i];
            console.log("Pilot Safe:", safe);
            bool safeIsNonClean;

            for (uint256 reserveId = 0; reserveId < reserveCount; ++reserveId) {
                uint256 supplied = spoke.getUserSuppliedAssets(reserveId, safe);
                uint256 debt = spoke.getUserTotalDebt(reserveId, safe);
                if (supplied != 0 || debt != 0) {
                    safeIsNonClean = true;
                    console.log("  asset:", spoke.getReserve(reserveId).underlying);
                    console.log("  supplied:", supplied);
                    console.log("  debt:", debt);
                }
            }

            // The original CashModule does not expose usesLendGateway, so a resumed rollback treats it as unavailable.
            (bool routeSuccess, bytes memory routeResult) = cashModule.staticcall(abi.encodeWithSelector(ICashModule.usesLendGateway.selector, safe));
            if (routeSuccess && routeResult.length == 32) console.log("  uses LendGateway:", abi.decode(routeResult, (bool)));
            else console.log("  uses LendGateway: unavailable on current implementation");
            console.log("  non-clean:", safeIsNonClean);
            if (safeIsNonClean) hasNonCleanSafe = true;
            positionHashes[i] = _positionHash(spoke, safe);
        }

        return (hasNonCleanSafe, positionHashes);
    }

    /// @dev Reads stable Aave user-position storage across every reserve so interest accrual cannot change the hash.
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

    /// @dev Confirms no selected Safe's underlying Aave storage changed during rollback simulation.
    function _requirePositionHashesUnchanged(IAaveV4Spoke spoke, address[] memory pilotSafes, bytes32[] memory expectedHashes) internal view {
        require(pilotSafes.length == expectedHashes.length, "position snapshot length mismatch");
        for (uint256 i = 0; i < pilotSafes.length; ++i) {
            require(_positionHash(spoke, pilotSafes[i]) == expectedHashes[i], "Aave pilot position changed");
        }
    }

    /// @dev Values the full Spoke conservatively using the Aave oracle.
    function _spokeTotalsUsd(IAaveV4Spoke spoke) internal view returns (uint256, uint256) {
        uint256 count = spoke.getReserveCount();
        uint256[] memory reserveIds = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            reserveIds[i] = i;
        }

        IAaveV4Oracle oracle = IAaveV4Oracle(spoke.ORACLE());
        (bool decimalsSuccess, bytes memory decimalsResult) = address(oracle).staticcall(abi.encodeWithSignature("decimals()"));
        require(decimalsSuccess && decimalsResult.length == 32 && abi.decode(decimalsResult, (uint8)) == 8, "unexpected Aave oracle decimals");

        uint256[] memory prices = oracle.getReservesPrices(reserveIds);
        require(prices.length == count, "Aave price length mismatch");

        uint256 supplyUsd;
        uint256 debtUsd;
        for (uint256 i = 0; i < count; ++i) {
            IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(i);
            require(reserve.decimals <= 36, "unsupported reserve decimals");
            uint256 unit = 10 ** reserve.decimals;
            supplyUsd += Math.mulDiv(spoke.getReserveSuppliedAssets(i), prices[i], unit, Math.Rounding.Ceil);
            debtUsd += Math.mulDiv(spoke.getReserveTotalDebt(i), prices[i], unit, Math.Rounding.Ceil);
        }
        return (supplyUsd, debtUsd);
    }

    /// @dev Logs aggregate Spoke values.
    function _logSpokeTotals(uint256 supplyUsd, uint256 debtUsd) internal pure {
        console.log("Aggregate Spoke supply USD (8 decimals):", supplyUsd);
        console.log("Aggregate Spoke debt USD (8 decimals):  ", debtUsd);
    }

    /// @dev Applies clean-only limits while allowing the explicit force mode to continue with warnings.
    function _enforceMode(RollbackMode mode, bool hasNonCleanSafe, uint256 supplyUsd, uint256 debtUsd) internal pure {
        if (mode == RollbackMode.CleanOnly) {
            require(!hasNonCleanSafe, "pilot Safe has Aave supply or debt");
            require(supplyUsd <= MAX_SPOKE_SUPPLY_USD, "Spoke supply exceeds $100");
            require(debtUsd <= MAX_SPOKE_DEBT_USD, "Spoke debt exceeds $100");
            return;
        }

        console.log("WARNING: force-implementations mode enabled");
        if (hasNonCleanSafe) console.log("WARNING: proceeding with non-clean pilot Safes");
        if (supplyUsd > MAX_SPOKE_SUPPLY_USD) console.log("WARNING: aggregate Spoke supply exceeds $100");
        if (debtUsd > MAX_SPOKE_DEBT_USD) console.log("WARNING: aggregate Spoke debt exceeds $100");
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

    /// @dev Writes the post-simulation verification snapshot consumed by VerifyCashLendRollbackDev.
    function _writeRollbackSnapshot(Deployment memory deployment, RollbackMode mode, address[] memory pilotSafes, bytes32[] memory positionHashes, bytes32 trackedGatewayStateHash, uint256 supplyUsd, uint256 debtUsd) internal {
        string memory object = "cash-lend-dev-rollback";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeString(object, "mode", mode == RollbackMode.CleanOnly ? "clean-only" : "force-implementations");
        vm.serializeAddress(object, "lendGateway", deployment.lendGateway);
        vm.serializeAddress(object, "spoke", deployment.spoke);
        vm.serializeAddress(object, "pilotSafes", pilotSafes);
        vm.serializeBytes32(object, "positionHashes", positionHashes);
        vm.serializeBytes32(object, "trackedGatewayStateHash", trackedGatewayStateHash);
        vm.serializeUint(object, "spokeSupplyUsd", supplyUsd);
        string memory output = vm.serializeUint(object, "spokeDebtUsd", debtUsd);

        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend-rollback.json");
        vm.writeJson(output, path);
        console.log("Rollback snapshot:", path);
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }
}
