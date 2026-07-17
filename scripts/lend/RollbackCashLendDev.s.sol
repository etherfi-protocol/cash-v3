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
import { CashLendDevModules } from "./CashLendDevModules.sol";

/**
 * @title RollbackCashLendDev
 * @notice Restores the implementations that preceded the Optimism dev Cash Lend deployment
 * @dev Dev-only implementation rollback. It never repays, withdraws, or changes LendGateway/Aave
 *      configuration; it only moves implementation references back to the rollback baseline and
 *      restores the old modules. It stops if aggregate Spoke supply or debt exceeds $100 unless
 *      SKIP_FUND_CHECK=true is set.
 *
 *      Each reference change is a separate EOA transaction, so the checks are a preflight, not an
 *      atomic guard. If broadcasting stops partway, rerun this script: it skips already-restored
 *      references. Run VerifyCashLendRollbackDev afterwards against the final chain state.
 *
 * Usage:
 *   source .env && ENV=dev forge script \
 *     scripts/lend/RollbackCashLendDev.s.sol:RollbackCashLendDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract RollbackCashLendDev is Utils {
    using Math for uint256;

    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant ORACLE_USD_SCALE = 1e8;
    uint256 internal constant MAX_SPOKE_SUPPLY_USD = 100 * ORACLE_USD_SCALE;
    uint256 internal constant MAX_SPOKE_DEBT_USD = 100 * ORACLE_USD_SCALE;

    struct Deployment {
        // Canonical dev proxies from the base deployment file.
        address cashEventEmitter;
        address cashLens;
        address cashModule;
        address dataProvider;
        address debtManager;
        address etherFiHook;
        address roleRegistry;
        address topUpDest;
        // Lend implementations from the deployment record.
        address cashEventEmitterImpl;
        address cashLensImpl;
        address cashModuleCoreImpl;
        address cashModuleSettersImpl;
        address debtManagerAdminImpl;
        address debtManagerCoreImpl;
        address etherFiHookImpl;
        address topUpDestImpl;
        address lendGateway;
        address lendGatewayImpl;
        address spoke;
        address[] newModules;
        address liquifierImplementation;
        // Rollback targets from the committed baseline.
        address previousCashEventEmitterImpl;
        address previousCashLensImpl;
        address previousCashModuleCoreImpl;
        address previousCashModuleSettersImpl;
        address previousDebtManagerAdminImpl;
        address previousDebtManagerCoreImpl;
        address previousEtherFiHookImpl;
        address previousTopUpDestImpl;
        address[] oldModules;
        address liquifier;
        address previousLiquifierImplementation;
    }

    /// @dev Validates rollback intent and chain state, then restores baseline implementations and modules.
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        Deployment memory d = _readDeployment();
        _validateDevAdmin(d, tx.origin);
        _requireExpectedTransition(d);

        // Stop while meaningful funds sit on the test Spoke, unless explicitly overridden.
        if (vm.envOr("SKIP_FUND_CHECK", false)) {
            console.log("WARNING: SKIP_FUND_CHECK set, not valuing the Spoke");
        } else {
            (uint256 supplyUsd, uint256 debtUsd) = _spokeTotalsUsd(IAaveV4Spoke(d.spoke));
            console.log("Aggregate Spoke supply USD (8 decimals):", supplyUsd);
            console.log("Aggregate Spoke debt USD (8 decimals):  ", debtUsd);
            _requireFundsWithinLimits(supplyUsd, debtUsd);
        }

        vm.startBroadcast();
        // Restore old module usability and retire the new modules before any Cash implementation moves back.
        CashLendDevModules.restoreOld(d.dataProvider, d.cashModule, LendGateway(d.lendGateway), d.oldModules, d.newModules);
        if (_implementationOf(d.liquifier) != d.previousLiquifierImplementation) {
            UUPSUpgradeable(d.liquifier).upgradeToAndCall(d.previousLiquifierImplementation, "");
        }
        _restoreImplementations(d);
        vm.stopBroadcast();

        console.log("Rollback broadcast, now run VerifyCashLendRollbackDev and delete cash-lend.json before redeploying");
    }

    /// @dev Confirms the CLI sender holds every role the restore calls need.
    function _validateDevAdmin(Deployment memory d, address sender) internal view {
        RoleRegistry registry = RoleRegistry(d.roleRegistry);
        require(registry.owner() == sender, "sender is not Cash dev admin");
        require(registry.hasRole(ICashModule(d.cashModule).CASH_MODULE_CONTROLLER_ROLE(), sender), "dev admin missing CashModule controller role");
        require(registry.hasRole(keccak256("DATA_PROVIDER_ADMIN_ROLE"), sender), "dev admin missing DataProvider admin role");
        require(registry.hasRole(keccak256("LEND_GATEWAY_ADMIN_ROLE"), sender), "dev admin missing LendGateway admin role");
    }

    /// @dev Loads proxies from the base file, Lend addresses from the record, and targets from the baseline.
    function _readDeployment() internal view returns (Deployment memory) {
        Deployment memory d;

        string memory baseJson = readDeploymentFile();
        d.cashEventEmitter = stdJson.readAddress(baseJson, ".addresses.CashEventEmitter");
        d.cashLens = stdJson.readAddress(baseJson, ".addresses.CashLens");
        d.cashModule = stdJson.readAddress(baseJson, ".addresses.CashModule");
        d.dataProvider = stdJson.readAddress(baseJson, ".addresses.EtherFiDataProvider");
        d.debtManager = stdJson.readAddress(baseJson, ".addresses.DebtManager");
        d.etherFiHook = stdJson.readAddress(baseJson, ".addresses.EtherFiHook");
        d.roleRegistry = stdJson.readAddress(baseJson, ".addresses.RoleRegistry");
        d.topUpDest = stdJson.readAddress(baseJson, ".addresses.TopUpDest");

        string memory record = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json"));
        require(stdJson.readUint(record, ".chainId") == block.chainid, "deployment record chain mismatch");
        d.cashEventEmitterImpl = stdJson.readAddress(record, ".cashEventEmitterImpl");
        d.cashLensImpl = stdJson.readAddress(record, ".cashLensImpl");
        d.cashModuleCoreImpl = stdJson.readAddress(record, ".cashModuleCoreImpl");
        d.cashModuleSettersImpl = stdJson.readAddress(record, ".cashModuleSettersImpl");
        d.debtManagerAdminImpl = stdJson.readAddress(record, ".debtManagerAdminImpl");
        d.debtManagerCoreImpl = stdJson.readAddress(record, ".debtManagerCoreImpl");
        d.etherFiHookImpl = stdJson.readAddress(record, ".etherFiHookImpl");
        d.topUpDestImpl = stdJson.readAddress(record, ".topUpDestImpl");
        d.lendGateway = stdJson.readAddress(record, ".lendGateway");
        d.lendGatewayImpl = stdJson.readAddress(record, ".lendGatewayImpl");
        d.spoke = stdJson.readAddress(record, ".spoke");
        d.newModules = CashLendDevModules.readNew(record);
        d.liquifierImplementation = stdJson.readAddress(record, ".liquifierImplementation");

        string memory baseline = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend-rollback-baseline.json"));
        require(stdJson.readUint(baseline, ".chainId") == block.chainid, "rollback baseline chain mismatch");
        d.previousCashEventEmitterImpl = stdJson.readAddress(baseline, ".cashEventEmitterImpl");
        d.previousCashLensImpl = stdJson.readAddress(baseline, ".cashLensImpl");
        d.previousCashModuleCoreImpl = stdJson.readAddress(baseline, ".cashModuleCoreImpl");
        d.previousCashModuleSettersImpl = stdJson.readAddress(baseline, ".cashModuleSettersImpl");
        d.previousDebtManagerAdminImpl = stdJson.readAddress(baseline, ".debtManagerAdminImpl");
        d.previousDebtManagerCoreImpl = stdJson.readAddress(baseline, ".debtManagerCoreImpl");
        d.previousEtherFiHookImpl = stdJson.readAddress(baseline, ".etherFiHookImpl");
        d.previousTopUpDestImpl = stdJson.readAddress(baseline, ".topUpDestImpl");
        d.oldModules = CashLendDevModules.oldAddresses(_baselineModules(baseline));
        d.liquifier = stdJson.readAddress(baseline, ".liquifier");
        d.previousLiquifierImplementation = stdJson.readAddress(baseline, ".liquifierImplementation");
        return d;
    }

    /// @dev Rebuilds the old module struct from the committed baseline file.
    function _baselineModules(string memory baseline) internal pure returns (CashLendDevModules.OldModules memory) {
        CashLendDevModules.OldModules memory old;
        old.openOcean = stdJson.readAddress(baseline, ".openOcean");
        old.liquid = stdJson.readAddress(baseline, ".liquid");
        old.liquidReferrer = stdJson.readAddress(baseline, ".liquidReferrer");
        old.frax = stdJson.readAddress(baseline, ".frax");
        old.stake = stdJson.readAddress(baseline, ".stake");
        old.midas = stdJson.readAddress(baseline, ".midas");
        old.beHype = stdJson.readAddress(baseline, ".beHype");
        old.liquifier = stdJson.readAddress(baseline, ".liquifier");
        return old;
    }

    /// @dev Requires the chain to be inside the recorded transition: every reference is either the Lend
    ///      version or the baseline version, and every rollback target still has code.
    function _requireExpectedTransition(Deployment memory d) internal view {
        require(d.newModules.length == 7 && d.oldModules.length == 7, "module list length mismatch");
        for (uint256 i = 0; i < 7; ++i) {
            require(d.oldModules[i].code.length != 0 && d.newModules[i].code.length != 0, "module code missing");
        }
        require(d.previousCashEventEmitterImpl.code.length != 0, "previous CashEventEmitter code missing");
        require(d.previousCashLensImpl.code.length != 0, "previous CashLens code missing");
        require(d.previousCashModuleCoreImpl.code.length != 0, "previous CashModule core code missing");
        require(d.previousCashModuleSettersImpl.code.length != 0, "previous CashModule setters code missing");
        require(d.previousDebtManagerAdminImpl.code.length != 0, "previous DebtManager admin code missing");
        require(d.previousDebtManagerCoreImpl.code.length != 0, "previous DebtManager core code missing");
        require(d.previousEtherFiHookImpl.code.length != 0, "previous EtherFiHook code missing");
        require(d.previousTopUpDestImpl.code.length != 0, "previous TopUpDest code missing");
        require(d.previousLiquifierImplementation.code.length != 0, "previous liquifier code missing");

        _requireRollbackReference(_implementationOf(d.cashEventEmitter), d.cashEventEmitterImpl, d.previousCashEventEmitterImpl);
        _requireRollbackReference(_implementationOf(d.cashLens), d.cashLensImpl, d.previousCashLensImpl);
        _requireRollbackReference(_implementationOf(d.cashModule), d.cashModuleCoreImpl, d.previousCashModuleCoreImpl);
        _requireRollbackReference(CashModuleCore(d.cashModule).getCashModuleSetters(), d.cashModuleSettersImpl, d.previousCashModuleSettersImpl);
        _requireRollbackReference(_implementationOf(d.debtManager), d.debtManagerCoreImpl, d.previousDebtManagerCoreImpl);
        _requireRollbackReference(IDebtManager(d.debtManager).getDebtManagerAdmin(), d.debtManagerAdminImpl, d.previousDebtManagerAdminImpl);
        _requireRollbackReference(_implementationOf(d.etherFiHook), d.etherFiHookImpl, d.previousEtherFiHookImpl);
        _requireRollbackReference(_implementationOf(d.topUpDest), d.topUpDestImpl, d.previousTopUpDestImpl);
        _requireRollbackReference(_implementationOf(d.liquifier), d.liquifierImplementation, d.previousLiquifierImplementation);
        require(_implementationOf(d.lendGateway) == d.lendGatewayImpl, "LendGateway changed since deployment");
    }

    /// @dev Allows a fresh rollback or a resumed partially completed rollback, but rejects unknown versions.
    function _requireRollbackReference(address current, address lend, address original) internal pure {
        require(current == lend || current == original, "implementation is outside rollback transition");
    }

    /// @dev Restores the eight baseline implementation references, skipping ones already restored.
    function _restoreImplementations(Deployment memory d) internal {
        // Roll back in reverse deployment order and keep pointer/core pairs adjacent.
        if (_implementationOf(d.topUpDest) != d.previousTopUpDestImpl) {
            UUPSUpgradeable(d.topUpDest).upgradeToAndCall(d.previousTopUpDestImpl, "");
        }
        if (_implementationOf(d.etherFiHook) != d.previousEtherFiHookImpl) {
            UUPSUpgradeable(d.etherFiHook).upgradeToAndCall(d.previousEtherFiHookImpl, "");
        }

        if (IDebtManager(d.debtManager).getDebtManagerAdmin() != d.previousDebtManagerAdminImpl) {
            IDebtManager(d.debtManager).setAdminImpl(d.previousDebtManagerAdminImpl);
        }
        if (_implementationOf(d.debtManager) != d.previousDebtManagerCoreImpl) {
            UUPSUpgradeable(d.debtManager).upgradeToAndCall(d.previousDebtManagerCoreImpl, "");
        }

        if (_implementationOf(d.cashEventEmitter) != d.previousCashEventEmitterImpl) {
            UUPSUpgradeable(d.cashEventEmitter).upgradeToAndCall(d.previousCashEventEmitterImpl, "");
        }
        if (_implementationOf(d.cashLens) != d.previousCashLensImpl) {
            UUPSUpgradeable(d.cashLens).upgradeToAndCall(d.previousCashLensImpl, "");
        }

        if (CashModuleCore(d.cashModule).getCashModuleSetters() != d.previousCashModuleSettersImpl) {
            ICashModule(d.cashModule).setCashModuleSettersAddress(d.previousCashModuleSettersImpl);
        }
        if (_implementationOf(d.cashModule) != d.previousCashModuleCoreImpl) {
            UUPSUpgradeable(d.cashModule).upgradeToAndCall(d.previousCashModuleCoreImpl, "");
        }
    }

    /// @dev Stops the rollback while the test Spoke holds more than $100 of supply or debt.
    function _requireFundsWithinLimits(uint256 supplyUsd, uint256 debtUsd) internal pure {
        require(supplyUsd <= MAX_SPOKE_SUPPLY_USD, "Spoke supply exceeds $100");
        require(debtUsd <= MAX_SPOKE_DEBT_USD, "Spoke debt exceeds $100");
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

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }
}
