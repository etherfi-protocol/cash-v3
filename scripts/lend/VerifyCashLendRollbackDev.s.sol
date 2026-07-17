// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { Utils } from "../utils/Utils.sol";
import { CashLendDevModules } from "./CashLendDevModules.sol";

/**
 * @title VerifyCashLendRollbackDev
 * @notice Verifies the rollback produced by RollbackCashLendDev
 * @dev Dev-only and read-only. Run it after the rollback broadcast, while cash-lend.json still exists;
 *      it confirms every reference is back at the rollback baseline, the old modules are restored with
 *      the dev policy, and the new modules are fully retired.
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
        address dataProvider;
        address debtManager;
        address etherFiHook;
        address topUpDest;
        address lendGateway;
        address lendGatewayImpl;
        address[] newModules;
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

    /// @dev Loads the record and baseline, then checks the chain is back at the pre-Lend state.
    function run() public view {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        Deployment memory d = _readDeployment();
        _requireBaselineImplementations(d);
        _requireBaselineImmutables(d);
        CashLendDevModules.verifyRestored(d.dataProvider, d.cashModule, LendGateway(d.lendGateway), d.oldModules, d.newModules);
        require(_implementationOf(d.liquifier) == d.previousLiquifierImplementation, "liquifier rollback mismatch");

        // The rollback must not have replaced the gateway itself.
        require(_implementationOf(d.lendGateway) == d.lendGatewayImpl, "LendGateway implementation changed");

        console.log("Cash Lend dev rollback verified");
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
        d.topUpDest = stdJson.readAddress(baseJson, ".addresses.TopUpDest");

        string memory record = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json"));
        require(stdJson.readUint(record, ".chainId") == block.chainid, "deployment record chain mismatch");
        d.lendGateway = stdJson.readAddress(record, ".lendGateway");
        d.lendGatewayImpl = stdJson.readAddress(record, ".lendGatewayImpl");
        d.newModules = CashLendDevModules.readNew(record);

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
        address[7] memory baselineModules = [stdJson.readAddress(baseline, ".openOcean"), stdJson.readAddress(baseline, ".liquid"), stdJson.readAddress(baseline, ".liquidReferrer"), stdJson.readAddress(baseline, ".frax"), stdJson.readAddress(baseline, ".stake"), stdJson.readAddress(baseline, ".midas"), stdJson.readAddress(baseline, ".beHype")];
        d.oldModules = new address[](7);
        for (uint256 i = 0; i < 7; ++i) {
            d.oldModules[i] = baselineModules[i];
        }
        d.liquifier = stdJson.readAddress(baseline, ".liquifier");
        d.previousLiquifierImplementation = stdJson.readAddress(baseline, ".liquifierImplementation");
        return d;
    }

    /// @dev Confirms every proxy and delegated pointer references its baseline implementation again.
    function _requireBaselineImplementations(Deployment memory d) internal view {
        require(_implementationOf(d.cashEventEmitter) == d.previousCashEventEmitterImpl, "CashEventEmitter rollback mismatch");
        require(_implementationOf(d.cashLens) == d.previousCashLensImpl, "CashLens rollback mismatch");
        require(_implementationOf(d.cashModule) == d.previousCashModuleCoreImpl, "CashModule rollback mismatch");
        require(CashModuleCore(d.cashModule).getCashModuleSetters() == d.previousCashModuleSettersImpl, "CashModule setters rollback mismatch");
        require(_implementationOf(d.debtManager) == d.previousDebtManagerCoreImpl, "DebtManager rollback mismatch");
        require(IDebtManager(d.debtManager).getDebtManagerAdmin() == d.previousDebtManagerAdminImpl, "DebtManager admin rollback mismatch");
        require(_implementationOf(d.etherFiHook) == d.previousEtherFiHookImpl, "EtherFiHook rollback mismatch");
        require(_implementationOf(d.topUpDest) == d.previousTopUpDestImpl, "TopUpDest rollback mismatch");
    }

    /// @dev Confirms the restored implementations were built for the canonical Cash proxies and dev dependencies.
    function _requireBaselineImmutables(Deployment memory d) internal view {
        address weth = getChainConfig(vm.toString(block.chainid)).weth;
        require(CashEventEmitter(d.previousCashEventEmitterImpl).cashModule() == d.cashModule, "previous CashEventEmitter cashModule mismatch");
        require(address(CashLens(d.previousCashLensImpl).cashModule()) == d.cashModule, "previous CashLens cashModule mismatch");
        require(address(CashLens(d.previousCashLensImpl).dataProvider()) == d.dataProvider, "previous CashLens dataProvider mismatch");
        require(address(CashModuleCore(d.previousCashModuleCoreImpl).etherFiDataProvider()) == d.dataProvider, "previous CashModule core dataProvider mismatch");
        require(address(CashModuleSetters(d.previousCashModuleSettersImpl).etherFiDataProvider()) == d.dataProvider, "previous CashModule setters dataProvider mismatch");
        require(address(DebtManagerCore(d.previousDebtManagerCoreImpl).etherFiDataProvider()) == d.dataProvider, "previous DebtManager core dataProvider mismatch");
        require(address(DebtManagerAdmin(d.previousDebtManagerAdminImpl).etherFiDataProvider()) == d.dataProvider, "previous DebtManager admin dataProvider mismatch");
        require(address(EtherFiHook(d.previousEtherFiHookImpl).dataProvider()) == d.dataProvider, "previous EtherFiHook dataProvider mismatch");
        require(address(TopUpDest(payable(d.previousTopUpDestImpl)).etherFiDataProvider()) == d.dataProvider, "previous TopUpDest dataProvider mismatch");
        require(address(TopUpDest(payable(d.previousTopUpDestImpl)).weth()) == weth, "previous TopUpDest WETH mismatch");
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }
}
