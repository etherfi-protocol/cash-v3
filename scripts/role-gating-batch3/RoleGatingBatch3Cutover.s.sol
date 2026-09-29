// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { BinSponsor, ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { RoleGatingBatch3Checks } from "./RoleGatingBatch3Checks.sol";

/// @title RoleGatingBatch3Cutover
/// @notice Generates the batch-3 Gnosis Safe Transaction Builder bundles for Optimism or Ethereum,
///         then simulates them on the fork and asserts the end state (plus a before/after snapshot
///         of every upgraded proxy's config, as a storage-layout safety net). No broadcast.
///
///         Three bundles per chain, all signed by the governance Safe (0xA6cf…AAC4):
///
///         multisend 1 (day 0) — schedule:
///           2-day upgrade timelock.scheduleBatch(cash upgrades)
///           8h operating timelock.scheduleBatch(module swap)            [OP only]
///         multisend 2 (day 2+) — execute, in this order:
///           2-day upgrade timelock.executeBatch(cash upgrades)
///           8h operating timelock.executeBatch(module swap)             [OP only]
///         trading (any time, independent) — direct calls from the Safe, which owns the trading
///           RoleRegistry: upgrade the registry, grant ADMIN_ROLE (Safe) + ADMIN_TIMELOCK_ROLE
///           (operating timelock), then upgrade every trading consumer
///
///         Why two timelocks on OP: upgrades, setCashModuleSettersAddress, setAdminImpl and the
///         liquid setLiquidAssetWithdrawQueue are RoleRegistry-OWNER calls (2-day timelock); the
///         module swap (configureDefaultModules, configureModulesCanRequestWithdraw,
///         LendGateway.setDriver) is gated on ADMIN_TIMELOCK_ROLE in the NEW code (8h timelock).
///         The module swap only works once the cash batch has executed, which is why it sits after
///         it in multisend 2 — both executes land atomically in one Safe tx.
///
///         Old modules are demoted from default but stay whitelisted and stay withdraw-requesters,
///         so any in-flight Liquid/Stargate bridge can still drain through them. Retiring them is a
///         later, separate 3CP (after scripts/lend/check-pending-withdrawals.sh is clean).
///
/// Usage (no broadcast — writes ./output/*.json and simulates):
///   ENV=mainnet forge script scripts/role-gating-batch3/RoleGatingBatch3Cutover.s.sol --rpc-url $OPTIMISM_RPC
///   ENV=mainnet forge script scripts/role-gating-batch3/RoleGatingBatch3Cutover.s.sol --rpc-url $MAINNET_RPC
contract RoleGatingBatch3Cutover is RoleGatingBatch3Checks, GnosisHelpers {
    struct TxItem {
        address to;
        bytes data;
    }

    /// @dev A read-only call whose result must be identical before and after the upgrade
    struct Probe {
        string label;
        address target;
        bytes data;
        bytes32 before;
    }

    address[] cashTargets;
    bytes[] cashPayloads;
    address[] moduleTargets;
    bytes[] modulePayloads;
    TxItem[] tradingTxs;
    Probe[] probes;

    function run() public {
        require(block.chainid == 10 || block.chainid == 1, "RoleGatingBatch3Cutover: Optimism or Ethereum only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        _checkTimelock(OPERATING_TIMELOCK, OPERATING_DELAY);

        OpLive memory opl;
        OpImpls memory opi;
        EthLive memory ethl;
        EthImpls memory ethi;
        if (block.chainid == 10) {
            opl = _readOpLive();
            opi = _readOpImpls();
            _preflightOp(opl, opi);
            _buildOp(opl, opi);
            _probesOp(opl);
        } else {
            ethl = _readEthLive();
            ethi = _readEthImpls();
            _preflightEth(ethl, ethi);
            _buildEth(ethl, ethi);
            _probesEth(ethl);
        }
        _snapshot();

        (string memory ms1, string memory ms2, string memory trading) = _writeBundles();

        // ── Simulate ──
        console.log("");
        console.log("=== Simulating multisend 1 (schedule) ===");
        executeGnosisTransactionBundle(ms1);
        if (block.chainid == 10) require(_implOf(opl.cashModule) != opi.cashModuleCore, "multisend 1 must not upgrade anything");
        else require(_implOf(ethl.stockUnwrapper) != ethi.stockUnwrapper, "multisend 1 must not upgrade anything");

        console.log("=== Simulating trading bundle (direct) ===");
        executeGnosisTransactionBundle(trading);

        console.log("=== Warping past the 2-day delay ===");
        vm.warp(block.timestamp + UPGRADE_DELAY + 1);

        console.log("=== Simulating multisend 2 (execute) ===");
        executeGnosisTransactionBundle(ms2);

        _checkProbes();
        if (block.chainid == 10) {
            _assertOpEndState(opl, opi);
            _probeNewGatesOp(opl);
        } else {
            _assertEthEndState(ethl, ethi);
        }
        _probeNewGatesTrading(block.chainid == 10 ? opl.tradingDataProvider : ethl.tradingDataProvider);

        console.log("");
        console.log("  [OK] batch-3 bundles simulated; end state verified");
    }

    // ─────────────────────────────── preflight ───────────────────────────────

    function _checkTimelock(address timelock, uint256 delay) internal view {
        require(keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == delay, "timelock: unexpected delay");
        require(tl.hasRole(tl.PROPOSER_ROLE(), SAFE) && tl.hasRole(tl.EXECUTOR_ROLE(), SAFE), "Safe is not proposer/executor");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock) && !tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), SAFE), "timelock admin misconfigured");
    }

    function _preflightCommon(address cashRegistry, address tradingRegistry) internal view {
        require(RoleRegistry(cashRegistry).owner() == UPGRADE_TIMELOCK, "cash RoleRegistry owner != 2-day timelock (batch 1/2 missing?)");
        require(_registryIsRegated(cashRegistry), "cash RoleRegistry not on re-gated code");
        RoleRegistry(cashRegistry).onlyAdmin(SAFE);
        RoleRegistry(cashRegistry).onlyAdminTimelock(OPERATING_TIMELOCK);

        require(RoleRegistry(tradingRegistry).owner() == SAFE, "trading RoleRegistry owner != Safe");
        require(!_registryIsRegated(tradingRegistry), "trading RoleRegistry already re-gated (batch 3 already ran?)");
    }

    function _preflightOp(OpLive memory l, OpImpls memory i) internal view {
        _preflightCommon(l.roleRegistry, l.tradingRoleRegistry);
        require(_implOf(l.cashModule) != i.cashModuleCore, "CashModule already on batch-3 impl");

        EtherFiDataProvider dp = EtherFiDataProvider(l.dataProvider);
        for (uint256 k = 0; k < N_MODULES; ++k) {
            require(l.oldModules[k] == i.oldModules[k], "deployments.json module != module recorded at deploy");
            // The swap below demotes every old module; it assumes all five are live defaults today
            require(dp.isDefaultModule(l.oldModules[k]) && dp.isWhitelistedModule(l.oldModules[k]), "old module is not a live default module");
            require(!dp.isWhitelistedModule(i.modules[k]), "new module already whitelisted");
        }
    }

    function _preflightEth(EthLive memory l, EthImpls memory i) internal view {
        _preflightCommon(l.roleRegistry, l.tradingRoleRegistry);
        require(_implOf(l.stockUnwrapper) != i.stockUnwrapper, "StockUnwrapper already on batch-3 impl");
    }

    // ─────────────────────────────── batches: Optimism ───────────────────────────────

    function _buildOp(OpLive memory l, OpImpls memory i) internal {
        // ── 2-day timelock: code changes (RoleRegistry-owner calls) ──
        _cash(l.cashModule, _upgrade(i.cashModuleCore));
        _cash(l.cashModule, abi.encodeWithSelector(ICashModule.setCashModuleSettersAddress.selector, i.cashModuleSetters));
        _cash(l.debtManager, _upgrade(i.debtManagerCore));
        _cash(l.debtManager, abi.encodeWithSelector(IDebtManager.setAdminImpl.selector, i.debtManagerAdmin));
        _cash(l.dataProvider, _upgrade(i.dataProvider));
        _cash(l.priceProvider, _upgrade(i.priceProvider));
        _cash(l.across, _upgrade(i.across));
        _cash(l.enso, _upgrade(i.enso));
        _cash(l.lendGateway, _upgrade(i.lendGateway));
        _cash(l.stockWithdrawModule, _upgrade(i.stockWithdrawModule));
        // Withdraw queues are post-constructor state; the new code gates the setter on the registry owner
        _pushQueueCopies(EtherFiLiquidModule(payable(l.oldModules[0])), i.modules[0]);
        _pushQueueCopies(EtherFiLiquidModule(payable(l.oldModules[1])), i.modules[1]);

        // ── 8h timelock: module swap (ADMIN_TIMELOCK_ROLE calls on the NEW code) ──
        for (uint256 k = 0; k < N_MODULES; ++k) {
            if (_isGatewayDriver(k)) _module(l.lendGateway, abi.encodeWithSelector(LendGateway.setDriver.selector, i.modules[k], true));
        }
        address[] memory swap = new address[](2 * N_MODULES);
        bool[] memory flags = new bool[](2 * N_MODULES);
        for (uint256 k = 0; k < N_MODULES; ++k) {
            swap[k] = i.modules[k];
            flags[k] = true;
            swap[N_MODULES + k] = l.oldModules[k];
            flags[N_MODULES + k] = false; // demote only: stays whitelisted
        }
        _module(l.dataProvider, abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, swap, flags));

        // New module inherits the old one's withdraw-requester status; the old one keeps it to drain
        address[] memory requesters = ICashModule(l.cashModule).getWhitelistedModulesCanRequestWithdraw();
        uint256 n;
        for (uint256 k = 0; k < N_MODULES; ++k) {
            if (_contains(requesters, l.oldModules[k])) ++n;
        }
        if (n > 0) {
            address[] memory newRequesters = new address[](n);
            bool[] memory yes = new bool[](n);
            uint256 j;
            for (uint256 k = 0; k < N_MODULES; ++k) {
                if (_contains(requesters, l.oldModules[k])) {
                    newRequesters[j] = i.modules[k];
                    yes[j++] = true;
                }
            }
            _module(l.cashModule, abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, newRequesters, yes));
        }

        // ── trading (direct from the Safe) ──
        _tradingRegistry(l.tradingRoleRegistry, i.tradingRoleRegistry);
        _trading(l.tradingDataProvider, _upgrade(i.dataProvider));
    }

    function _pushQueueCopies(EtherFiLiquidModule oldModule, address newModule) internal {
        address[9] memory assets = _liquidAssetCandidates();
        for (uint256 a = 0; a < assets.length; ++a) {
            address queue = oldModule.liquidWithdrawQueue(assets[a]);
            if (queue != address(0)) {
                _cash(newModule, abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, assets[a], queue));
            }
        }
    }

    // ─────────────────────────────── batches: Ethereum ───────────────────────────────

    function _buildEth(EthLive memory l, EthImpls memory i) internal {
        _cash(l.stockUnwrapper, _upgrade(i.stockUnwrapper));

        _tradingRegistry(l.tradingRoleRegistry, i.tradingRoleRegistry);
        _trading(l.tradingDataProvider, _upgrade(i.dataProvider));
        _trading(l.tradingPriceProvider, _upgrade(i.priceProvider));
        _trading(l.across, _upgrade(i.across));
        _trading(l.enso, _upgrade(i.enso));
        _trading(l.tradingLens, _upgrade(i.tradingLens));
    }

    /// @dev Registry first (consumers call its new onlyAdmin/onlyAdminTimelock), grants before any consumer
    function _tradingRegistry(address registry, address impl) internal {
        _trading(registry, _upgrade(impl));
        _trading(registry, abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_ROLE, SAFE));
        _trading(registry, abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_TIMELOCK_ROLE, OPERATING_TIMELOCK));
    }

    // ─────────────────────────────── bundle writing ───────────────────────────────

    function _writeBundles() internal returns (string memory ms1Path, string memory ms2Path, string memory tradingPath) {
        string memory chain = vm.toString(block.chainid);
        bool hasModules = moduleTargets.length > 0;

        string memory ms1 = _getGnosisHeader(chain, addressToHex(SAFE));
        ms1 = string.concat(ms1, _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), iToHex(_scheduleData(cashTargets, cashPayloads, TL_SALT_CASH, UPGRADE_DELAY)), "0", !hasModules));
        if (hasModules) {
            ms1 = string.concat(ms1, _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), iToHex(_scheduleData(moduleTargets, modulePayloads, TL_SALT_MODULES, OPERATING_DELAY)), "0", true));
        }

        string memory ms2 = _getGnosisHeader(chain, addressToHex(SAFE));
        ms2 = string.concat(ms2, _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), iToHex(_executeData(cashTargets, cashPayloads, TL_SALT_CASH)), "0", !hasModules));
        if (hasModules) {
            ms2 = string.concat(ms2, _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), iToHex(_executeData(moduleTargets, modulePayloads, TL_SALT_MODULES)), "0", true));
        }

        string memory tr = _getGnosisHeader(chain, addressToHex(SAFE));
        for (uint256 k = 0; k < tradingTxs.length; ++k) {
            tr = string.concat(tr, _getGnosisTransaction(addressToHex(tradingTxs[k].to), iToHex(tradingTxs[k].data), "0", k == tradingTxs.length - 1));
        }

        vm.createDir("./output", true);
        string memory base = string.concat("./output/RoleGatingBatch3Cutover-", chain, "-");
        ms1Path = string.concat(base, "multisend1-schedule.json");
        ms2Path = string.concat(base, "multisend2-execute.json");
        tradingPath = string.concat(base, "trading.json");
        vm.writeFile(ms1Path, ms1);
        vm.writeFile(ms2Path, ms2);
        vm.writeFile(tradingPath, tr);
        console.log("Wrote", ms1Path);
        console.log("Wrote", ms2Path);
        console.log("Wrote", tradingPath);
        console.log("  cash batch calls:   ", cashTargets.length);
        console.log("  module batch calls: ", moduleTargets.length);
        console.log("  trading calls:      ", tradingTxs.length);
    }

    function _scheduleData(address[] memory targets, bytes[] memory payloads, bytes32 salt, uint256 delay) internal pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.scheduleBatch, (targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt, delay));
    }

    function _executeData(address[] memory targets, bytes[] memory payloads, bytes32 salt) internal pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.executeBatch, (targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt));
    }

    function _upgrade(address impl) internal pure returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, bytes("")));
    }

    function _cash(address to, bytes memory data) internal {
        cashTargets.push(to);
        cashPayloads.push(data);
    }

    function _module(address to, bytes memory data) internal {
        moduleTargets.push(to);
        modulePayloads.push(data);
    }

    function _trading(address to, bytes memory data) internal {
        tradingTxs.push(TxItem({ to: to, data: data }));
    }

    // ─────────────────────────────── state-preservation probes ───────────────────────────────

    /// @dev Storage-layout safety net: config readable through the proxy must be byte-identical
    ///      before and after the new impl is in place. Only storage-backed getters — price() is
    ///      avoided because the 2-day warp makes oracles stale.
    function _probesOp(OpLive memory l) internal {
        _probeDataProvider("cash DP", l.dataProvider);
        _probeDataProvider("trading DP", l.tradingDataProvider);

        address cm = l.cashModule;
        _probe("CM.getDebtManager", cm, abi.encodeWithSelector(CashModuleCore.getDebtManager.selector));
        _probe("CM.getDelays", cm, abi.encodeWithSelector(CashModuleCore.getDelays.selector));
        _probe("CM.getWhitelistedWithdrawAssets", cm, abi.encodeWithSelector(CashModuleCore.getWhitelistedWithdrawAssets.selector));
        _probe("CM.getCashEventEmitter", cm, abi.encodeWithSelector(CashModuleCore.getCashEventEmitter.selector));
        _probe("CM.getLendGateway", cm, abi.encodeWithSelector(CashModuleCore.getLendGateway.selector));
        for (uint8 b = 0; b <= uint8(BinSponsor.CardOrder); ++b) {
            _probe("CM.getSettlementDispatcher", cm, abi.encodeWithSelector(CashModuleCore.getSettlementDispatcher.selector, BinSponsor(b)));
        }

        address dm = l.debtManager;
        address[] memory collaterals = DebtManagerCore(dm).getCollateralTokens();
        address[] memory borrows = DebtManagerCore(dm).getBorrowTokens();
        _probe("DM.getCollateralTokens", dm, abi.encodeWithSelector(DebtManagerCore.getCollateralTokens.selector));
        _probe("DM.getBorrowTokens", dm, abi.encodeWithSelector(DebtManagerCore.getBorrowTokens.selector));
        for (uint256 k = 0; k < collaterals.length; ++k) {
            _probe("DM.collateralTokenConfig", dm, abi.encodeWithSelector(DebtManagerCore.collateralTokenConfig.selector, collaterals[k]));
            _probe("PP.tokenConfig", l.priceProvider, abi.encodeWithSelector(PriceProviderV2.tokenConfig.selector, collaterals[k]));
        }
        for (uint256 k = 0; k < borrows.length; ++k) {
            _probe("DM.borrowTokenConfig", dm, abi.encodeWithSelector(DebtManagerCore.borrowTokenConfig.selector, borrows[k]));
        }

        _probeAcross(l.across);
        _probe("Enso.getEnsoRouter", l.enso, abi.encodeWithSelector(EnsoSwapModule.getEnsoRouter.selector));

        address gw = l.lendGateway;
        _probe("GW.minHealthFactor", gw, abi.encodeWithSelector(LendGateway.minHealthFactor.selector));
        _probe("GW.registeredAssets", gw, abi.encodeWithSelector(LendGateway.registeredAssets.selector));

        address sw = l.stockWithdrawModule;
        _probe("SW.getSupportedTokens", sw, abi.encodeWithSelector(StockWithdrawModule.getSupportedTokens.selector));
        _probe("SW.getConfiguredUnwrappers", sw, abi.encodeWithSelector(StockWithdrawModule.getConfiguredUnwrappers.selector));
        _probe("SW.getLzGasLimits", sw, abi.encodeWithSelector(StockWithdrawModule.getLzGasLimits.selector));
        _probe("SW.getProviderFee", sw, abi.encodeWithSelector(StockWithdrawModule.getProviderFee.selector));

        address[9] memory proxies = [l.cashModule, l.debtManager, l.dataProvider, l.priceProvider, l.across, l.enso, l.lendGateway, l.stockWithdrawModule, l.tradingDataProvider];
        for (uint256 k = 0; k < proxies.length; ++k) _probeProxyCommon(proxies[k]);
    }

    function _probesEth(EthLive memory l) internal {
        address su = l.stockUnwrapper;
        _probe("SU.getLzEndpoint", su, abi.encodeWithSelector(StockUnwrapper.getLzEndpoint.selector));
        _probe("SU.getSrcEid", su, abi.encodeWithSelector(StockUnwrapper.getSrcEid.selector));
        _probe("SU.getSrcModule", su, abi.encodeWithSelector(StockUnwrapper.getSrcModule.selector));
        _probe("SU.getRegisteredAdapters", su, abi.encodeWithSelector(StockUnwrapper.getRegisteredAdapters.selector));

        _probeDataProvider("trading DP", l.tradingDataProvider);
        _probeAcross(l.across);
        _probe("Enso.getEnsoRouter", l.enso, abi.encodeWithSelector(EnsoSwapModule.getEnsoRouter.selector));

        address[] memory tokens = TradingLens(l.tradingLens).getSupportedTokens();
        _probe("TL.getSupportedTokens", l.tradingLens, abi.encodeWithSelector(TradingLens.getSupportedTokens.selector));
        for (uint256 k = 0; k < tokens.length; ++k) {
            _probe("PP.tokenConfig", l.tradingPriceProvider, abi.encodeWithSelector(PriceProviderV2.tokenConfig.selector, tokens[k]));
        }

        address[6] memory proxies = [l.stockUnwrapper, l.tradingDataProvider, l.tradingPriceProvider, l.across, l.enso, l.tradingLens];
        for (uint256 k = 0; k < proxies.length; ++k) _probeProxyCommon(proxies[k]);
    }

    function _probeDataProvider(string memory label, address dp) internal {
        bytes4[9] memory sels = [
            EtherFiDataProvider.getCashModule.selector,
            EtherFiDataProvider.getPriceProvider.selector,
            EtherFiDataProvider.getHookAddress.selector,
            EtherFiDataProvider.getEtherFiSafeFactory.selector,
            EtherFiDataProvider.getCashLens.selector,
            EtherFiDataProvider.getRefundWallet.selector,
            EtherFiDataProvider.getEtherFiRecoverySigner.selector,
            EtherFiDataProvider.getThirdPartyRecoverySigner.selector,
            EtherFiDataProvider.getRecoveryDelayPeriod.selector
        ];
        for (uint256 k = 0; k < sels.length; ++k) _probe(label, dp, abi.encodeWithSelector(sels[k]));
    }

    function _probeAcross(address across) internal {
        _probe("Across.getSpokePool", across, abi.encodeWithSelector(AcrossSwapModule.getSpokePool.selector));
        _probe("Across.getMulticallHandler", across, abi.encodeWithSelector(AcrossSwapModule.getMulticallHandler.selector));
        _probe("Across.getPeriphery", across, abi.encodeWithSelector(AcrossSwapModule.getPeriphery.selector));
    }

    /// @dev UpgradeableProxy base storage: roleRegistry pointer (hijack detection) and pause flag
    function _probeProxyCommon(address proxy) internal {
        _probe("roleRegistry()", proxy, abi.encodeWithSignature("roleRegistry()"));
        _probe("paused()", proxy, abi.encodeWithSignature("paused()"));
    }

    function _probe(string memory label, address target, bytes memory data) internal {
        probes.push(Probe({ label: label, target: target, data: data, before: bytes32(0) }));
    }

    function _snapshot() internal {
        for (uint256 k = 0; k < probes.length; ++k) {
            (bool ok, bytes memory ret) = probes[k].target.staticcall(probes[k].data);
            require(ok, string.concat("probe failed before upgrade: ", probes[k].label));
            probes[k].before = keccak256(ret);
        }
    }

    function _checkProbes() internal view {
        for (uint256 k = 0; k < probes.length; ++k) {
            (bool ok, bytes memory ret) = probes[k].target.staticcall(probes[k].data);
            require(ok, string.concat("probe failed after upgrade: ", probes[k].label));
            require(keccak256(ret) == probes[k].before, string.concat("state changed across upgrade: ", probes[k].label));
        }
        console.log("  [OK] config snapshot identical before/after upgrade, probes:", probes.length);
    }

    // ─────────────────────────────── negative probes: new gates are live ───────────────────────────────

    /// @dev The Safe (ADMIN_ROLE, no ADMIN_TIMELOCK_ROLE) can no longer make trust changes directly
    function _probeNewGatesOp(OpLive memory l) internal {
        address[] memory one = new address[](1);
        one[0] = makeAddr("probeModule");
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        vm.prank(SAFE);
        (bool ok,) = l.dataProvider.call(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, one, yes));
        require(!ok, "Safe can still configureModules directly on cash DP");
        vm.prank(SAFE);
        (ok,) = l.lendGateway.call(abi.encodeWithSelector(LendGateway.setDriver.selector, one[0], true));
        require(!ok, "Safe can still setDriver directly");
        vm.prank(SAFE);
        (ok,) = l.cashModule.call(abi.encodeWithSelector(ICashModule.setCashModuleSettersAddress.selector, one[0]));
        require(!ok, "Safe can still swap CashModule setters directly");
        console.log("  [OK] re-gated OP cash functions reject the Safe");
    }

    function _probeNewGatesTrading(address tradingDp) internal {
        address[] memory one = new address[](1);
        one[0] = makeAddr("probeModule");
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        vm.prank(SAFE);
        (bool ok,) = tradingDp.call(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, one, yes));
        require(!ok, "Safe can still configureModules directly on trading DP");
        console.log("  [OK] re-gated trading DP rejects the Safe for trust changes");
    }
}
