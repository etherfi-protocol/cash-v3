// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4Oracle } from "../../src/interfaces/IAaveV4Oracle.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title RollbackCashLendDev
 * @notice Restores the implementations that preceded the Optimism dev Cash Lend deployment
 * @dev Test-only implementation rollback. It never repays, withdraws, or changes LendGateway/Aave
 *      configuration. `clean-only` fails closed on known pilot positions, unpriceable Spoke state,
 *      or aggregate Spoke supply/debt over $100. `force-implementations` logs those conditions and
 *      restores the implementations anyway. Each reference change is a separate EOA transaction;
 *      if broadcasting stops partway, rerun this script to skip restored references and resume.
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

        _validateDevAdmin(vm.envUint("PRIVATE_KEY"));
        _validatePilotSafes(pilotSafes);
        _requireExpectedImplementations(deployment);

        // Inspect explicitly supplied pilot Safes and retain stable Aave position hashes for post-rollback checks.
        (bool hasNonCleanSafe, bytes32[] memory positionHashes) = _inspectPilotSafes(deployment.cashModule, spoke, pilotSafes);

        // Value the entire Spoke at Aave oracle prices so an omitted pilot list cannot hide material market usage.
        (bool valuationAvailable, uint256 supplyUsd, uint256 debtUsd) = _spokeTotalsUsd(spoke);
        _logSpokeTotals(valuationAvailable, supplyUsd, debtUsd);
        _enforceMode(mode, hasNonCleanSafe, valuationAvailable, supplyUsd, debtUsd);

        bytes32 trackedGatewayStateHash = _trackedGatewayStateHash(deployment, gateway, spoke);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _restoreOriginalImplementations(deployment);
        vm.stopBroadcast();

        // Prove the simulated rollback changed only the implementation references described by the manifest.
        _requireOriginalImplementations(deployment);
        require(_trackedGatewayStateHash(deployment, gateway, spoke) == trackedGatewayStateHash, "tracked gateway state changed");
        _requirePositionHashesUnchanged(spoke, pilotSafes, positionHashes);

        _writeRollbackSnapshot(deployment, mode, pilotSafes, positionHashes, trackedGatewayStateHash, valuationAvailable, supplyUsd, debtUsd);
        console.log("Cash Lend dev implementation rollback simulated successfully");
    }

    /// @dev Parses the only two supported rollback modes and rejects ambiguous values.
    function _rollbackMode(string memory value) internal pure returns (RollbackMode) {
        if (keccak256(bytes(value)) == keccak256(bytes("clean-only"))) return RollbackMode.CleanOnly;
        if (keccak256(bytes(value)) == keccak256(bytes("force-implementations"))) return RollbackMode.ForceImplementations;
        revert("invalid ROLLBACK_MODE");
    }

    /// @dev Confirms the broadcast key is the existing Cash and Aave dev administrator.
    function _validateDevAdmin(uint256 privateKey) internal view {
        string memory baseJson = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(baseJson, ".addresses.RoleRegistry");
        address admin = RoleRegistry(roleRegistry).owner();
        require(vm.addr(privateKey) == admin, "PRIVATE_KEY is not Cash dev admin");

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
        return deployment;
    }

    /// @dev Requires the live deployment to still be the exact Lend version this manifest knows how to undo.
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
            hash = keccak256(abi.encode(hash, reserveId, position));
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

    /// @dev Converts any valuation failure into an unavailable result so force mode can still proceed.
    function _spokeTotalsUsd(IAaveV4Spoke spoke) internal view returns (bool, uint256, uint256) {
        try this.calculateSpokeTotalsUsd(spoke) returns (uint256 supplyUsd, uint256 debtUsd) {
            return (true, supplyUsd, debtUsd);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Values the full Spoke conservatively; the external self-call lets the caller catch every failure.
    function calculateSpokeTotalsUsd(IAaveV4Spoke spoke) external view returns (uint256, uint256) {
        require(msg.sender == address(this), "self call only");
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
            _requireFreshnessAwareSource(address(oracle), i);
            IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(i);
            require(reserve.decimals <= 36, "unsupported reserve decimals");
            uint256 unit = 10 ** reserve.decimals;
            supplyUsd += Math.mulDiv(spoke.getReserveSuppliedAssets(i), prices[i], unit, Math.Rounding.Ceil);
            debtUsd += Math.mulDiv(spoke.getReserveTotalDebt(i), prices[i], unit, Math.Rounding.Ceil);
        }
        return (supplyUsd, debtUsd);
    }

    /// @dev Rejects raw oracle sources that expose no staleness bound; force mode may explicitly bypass this check.
    function _requireFreshnessAwareSource(address oracle, uint256 reserveId) internal view {
        (bool sourceSuccess, bytes memory sourceResult) = oracle.staticcall(abi.encodeWithSignature("getReserveSource(uint256)", reserveId));
        require(sourceSuccess && sourceResult.length == 32, "Aave reserve source unavailable");
        address source = abi.decode(sourceResult, (address));

        (bool rateSuccess, bytes memory rateResult) = source.staticcall(abi.encodeWithSignature("rateMaxStaleness()"));
        (bool priceSuccess, bytes memory priceResult) = source.staticcall(abi.encodeWithSignature("maxStaleness()"));
        bool rateBound = rateSuccess && rateResult.length == 32 && abi.decode(rateResult, (uint256)) != 0;
        bool priceBound = priceSuccess && priceResult.length == 32 && abi.decode(priceResult, (uint256)) != 0;
        require(rateBound || priceBound, "reserve source has no staleness bound");
    }

    /// @dev Logs aggregate Spoke values or an explicit warning when an oracle prevents valuation.
    function _logSpokeTotals(bool valuationAvailable, uint256 supplyUsd, uint256 debtUsd) internal pure {
        if (!valuationAvailable) {
            console.log("WARNING: aggregate Spoke valuation unavailable");
            return;
        }
        console.log("Aggregate Spoke supply USD (8 decimals):", supplyUsd);
        console.log("Aggregate Spoke debt USD (8 decimals):  ", debtUsd);
    }

    /// @dev Applies clean-only guards while allowing the explicit force mode to proceed with warnings.
    function _enforceMode(RollbackMode mode, bool hasNonCleanSafe, bool valuationAvailable, uint256 supplyUsd, uint256 debtUsd) internal pure {
        if (mode == RollbackMode.CleanOnly) {
            require(!hasNonCleanSafe, "pilot Safe has Aave supply or debt");
            require(valuationAvailable, "Spoke valuation unavailable");
            require(supplyUsd <= MAX_SPOKE_SUPPLY_USD, "Spoke supply exceeds $100");
            require(debtUsd <= MAX_SPOKE_DEBT_USD, "Spoke debt exceeds $100");
            return;
        }

        console.log("WARNING: force-implementations mode enabled");
        if (hasNonCleanSafe) console.log("WARNING: proceeding with non-clean pilot Safes");
        if (!valuationAvailable) console.log("WARNING: proceeding without aggregate Spoke valuation");
        if (valuationAvailable && supplyUsd > MAX_SPOKE_SUPPLY_USD) console.log("WARNING: aggregate Spoke supply exceeds $100");
        if (valuationAvailable && debtUsd > MAX_SPOKE_DEBT_USD) console.log("WARNING: aggregate Spoke debt exceeds $100");
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

    /// @dev Writes the post-simulation verification snapshot consumed by VerifyCashLendRollbackDev.
    function _writeRollbackSnapshot(Deployment memory deployment, RollbackMode mode, address[] memory pilotSafes, bytes32[] memory positionHashes, bytes32 trackedGatewayStateHash, bool valuationAvailable, uint256 supplyUsd, uint256 debtUsd) internal {
        string memory object = "cash-lend-dev-rollback";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeString(object, "mode", mode == RollbackMode.CleanOnly ? "clean-only" : "force-implementations");
        vm.serializeAddress(object, "lendGateway", deployment.lendGateway);
        vm.serializeAddress(object, "spoke", deployment.spoke);
        vm.serializeAddress(object, "pilotSafes", pilotSafes);
        vm.serializeBytes32(object, "positionHashes", positionHashes);
        vm.serializeBytes32(object, "trackedGatewayStateHash", trackedGatewayStateHash);
        vm.serializeBool(object, "valuationAvailable", valuationAvailable);
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
