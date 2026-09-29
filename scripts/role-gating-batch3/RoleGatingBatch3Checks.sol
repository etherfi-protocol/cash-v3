// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { RoleGatingBatch3Config } from "./RoleGatingBatch3Config.sol";

/**
 * @title RoleGatingBatch3Checks
 * @notice Deployment-record readers and the end-state assertions shared by the cutover (after its
 *         fork simulation) and the verifier (against the live chain after the Safe executes).
 *         Every check is a require — a failure reverts, never just logs.
 */
abstract contract RoleGatingBatch3Checks is RoleGatingBatch3Config {
    struct OpImpls {
        address cashModuleCore;
        address cashModuleSetters;
        address debtManagerCore;
        address debtManagerAdmin;
        address dataProvider;
        address priceProvider;
        address across;
        address enso;
        address lendGateway;
        address stockWithdrawModule;
        address[5] modules;
        address tradingRoleRegistry;
    }

    struct EthImpls {
        address stockUnwrapper;
        address tradingRoleRegistry;
        address dataProvider;
        address priceProvider;
        address across;
        address enso;
        address tradingLens;
    }

    function _readOpImpls() internal view returns (OpImpls memory i) {
        string memory r = _readRecord();
        i.cashModuleCore = _recorded(r, "cashModuleCoreImpl", "CashModuleCoreImpl");
        i.cashModuleSetters = _recorded(r, "cashModuleSettersImpl", "CashModuleSettersImpl");
        i.debtManagerCore = _recorded(r, "debtManagerCoreImpl", "DebtManagerCoreImpl");
        i.debtManagerAdmin = _recorded(r, "debtManagerAdminImpl", "DebtManagerAdminImpl");
        i.dataProvider = _recorded(r, "dataProviderImpl", "EtherFiDataProviderImpl");
        i.priceProvider = _recorded(r, "priceProviderImpl", "PriceProviderV2Impl");
        i.across = _recorded(r, "acrossImpl", "AcrossSwapModuleImpl");
        i.enso = _recorded(r, "ensoImpl", "EnsoSwapModuleImpl");
        i.lendGateway = _recorded(r, "lendGatewayImpl", "LendGatewayImpl");
        i.stockWithdrawModule = _recorded(r, "stockWithdrawModuleImpl", "StockWithdrawModuleImpl");
        string[5] memory keys = _moduleKeys();
        string[5] memory salts = _moduleSaltNames();
        for (uint256 k = 0; k < N_MODULES; ++k) {
            i.modules[k] = _recorded(r, keys[k], salts[k]);
        }
        i.tradingRoleRegistry = _recorded(r, "tradingRoleRegistryImpl", "TradingRoleRegistryImpl");
    }

    function _readEthImpls() internal view returns (EthImpls memory i) {
        string memory r = _readRecord();
        i.stockUnwrapper = _recorded(r, "stockUnwrapperImpl", "StockUnwrapperImpl");
        i.tradingRoleRegistry = _recorded(r, "tradingRoleRegistryImpl", "TradingRoleRegistryImpl");
        i.dataProvider = _recorded(r, "dataProviderImpl", "EtherFiDataProviderImpl");
        i.priceProvider = _recorded(r, "priceProviderImpl", "PriceProviderV2Impl");
        i.across = _recorded(r, "acrossImpl", "AcrossSwapModuleImpl");
        i.enso = _recorded(r, "ensoImpl", "EnsoSwapModuleImpl");
        i.tradingLens = _recorded(r, "tradingLensImpl", "TradingLensImpl");
    }

    // ─────────────────────────────── end state: Optimism ───────────────────────────────

    function _assertOpEndState(OpLive memory l, OpImpls memory i) internal view {
        // Cash proxies + delegated impls
        _requireImpl(l.cashModule, i.cashModuleCore, "CashModule");
        require(CashModuleCore(payable(l.cashModule)).getCashModuleSetters() == i.cashModuleSetters, "CashModule setters != new impl");
        _requireImpl(l.debtManager, i.debtManagerCore, "DebtManager");
        require(DebtManagerCore(l.debtManager).getDebtManagerAdmin() == i.debtManagerAdmin, "DebtManager admin != new impl");
        _requireImpl(l.dataProvider, i.dataProvider, "EtherFiDataProvider");
        _requireImpl(l.priceProvider, i.priceProvider, "PriceProvider");
        _requireImpl(l.across, i.across, "AcrossSwapModule");
        _requireImpl(l.enso, i.enso, "EnsoSwapModule");
        _requireImpl(l.lendGateway, i.lendGateway, "LendGateway");
        _requireImpl(l.stockWithdrawModule, i.stockWithdrawModule, "StockWithdrawModule");

        // Module swap: new modules default + mirrored requester/driver status; old ones demoted
        // but still whitelisted (and still requesters) so in-flight bridges can drain
        EtherFiDataProvider dp = EtherFiDataProvider(l.dataProvider);
        address[] memory requesters = ICashModule(l.cashModule).getWhitelistedModulesCanRequestWithdraw();
        LendGateway gw = LendGateway(l.lendGateway);
        for (uint256 k = 0; k < N_MODULES; ++k) {
            address oldM = l.oldModules[k];
            address newM = i.modules[k];
            require(dp.isDefaultModule(newM) && dp.isWhitelistedModule(newM), "new module not default");
            require(!dp.isDefaultModule(oldM), "old module still default");
            require(dp.isWhitelistedModule(oldM), "old module must stay whitelisted until drained");
            require(_contains(requesters, newM) == _contains(requesters, oldM), "new module requester status != old");
            if (_isGatewayDriver(k)) require(gw.isDriver(newM), "new sandwich module is not a LendGateway driver");
        }

        // Withdraw queues are post-constructor state on the liquid modules
        address[9] memory assets = _liquidAssetCandidates();
        for (uint256 k = 0; k < 2; ++k) {
            EtherFiLiquidModule oldM = EtherFiLiquidModule(payable(l.oldModules[k]));
            EtherFiLiquidModule newM = EtherFiLiquidModule(payable(i.modules[k]));
            for (uint256 a = 0; a < assets.length; ++a) {
                require(newM.liquidWithdrawQueue(assets[a]) == oldM.liquidWithdrawQueue(assets[a]), "liquid withdraw queue not copied");
            }
        }

        // Trading stack
        _requireImpl(l.tradingRoleRegistry, i.tradingRoleRegistry, "trading RoleRegistry");
        _requireImpl(l.tradingDataProvider, i.dataProvider, "trading EtherFiDataProvider");

        _assertGovernance(l.roleRegistry, l.tradingRoleRegistry);
        console.log("  [OK] Optimism batch-3 end state");
    }

    // ─────────────────────────────── end state: Ethereum ───────────────────────────────

    function _assertEthEndState(EthLive memory l, EthImpls memory i) internal view {
        _requireImpl(l.stockUnwrapper, i.stockUnwrapper, "StockUnwrapper");
        _requireImpl(l.tradingRoleRegistry, i.tradingRoleRegistry, "trading RoleRegistry");
        _requireImpl(l.tradingDataProvider, i.dataProvider, "trading EtherFiDataProvider");
        _requireImpl(l.tradingPriceProvider, i.priceProvider, "trading PriceProvider");
        _requireImpl(l.across, i.across, "AcrossSwapModule");
        _requireImpl(l.enso, i.enso, "EnsoSwapModule");
        _requireImpl(l.tradingLens, i.tradingLens, "TradingLens");

        _assertGovernance(l.roleRegistry, l.tradingRoleRegistry);
        console.log("  [OK] Ethereum batch-3 end state");
    }

    // ─────────────────────────────── governance (post-op ownership hook) ───────────────────────────────

    /// @dev Last check on every run: registry owners and timelock delays unchanged, roles in place.
    ///      Catches anything injected into a batch that moved ownership mid-execution.
    function _assertGovernance(address cashRegistry, address tradingRegistry) internal view {
        RoleRegistry cash = RoleRegistry(cashRegistry);
        RoleRegistry trading = RoleRegistry(tradingRegistry);

        require(cash.owner() == UPGRADE_TIMELOCK, "CRITICAL: cash RoleRegistry owner changed");
        require(trading.owner() == SAFE, "CRITICAL: trading RoleRegistry owner changed");
        require(EtherFiTimelock(payable(UPGRADE_TIMELOCK)).getMinDelay() == UPGRADE_DELAY, "upgrade timelock delay changed");
        require(EtherFiTimelock(payable(OPERATING_TIMELOCK)).getMinDelay() == OPERATING_DELAY, "operating timelock delay changed");

        cash.onlyAdmin(SAFE);
        cash.onlyAdminTimelock(OPERATING_TIMELOCK);
        trading.onlyAdmin(SAFE);
        trading.onlyAdminTimelock(OPERATING_TIMELOCK);
        require(!trading.hasRole(ADMIN_TIMELOCK_ROLE, SAFE), "Safe must not hold ADMIN_TIMELOCK_ROLE on trading registry");
        console.log("  [OK] registry owners, timelock delays and admin roles unchanged/in place");
    }

    function _requireImpl(address proxy, address expected, string memory name) internal view {
        require(_implOf(proxy) == expected, string.concat(name, ": impl slot != batch-3 impl"));
    }
}
