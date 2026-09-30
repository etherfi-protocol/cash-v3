// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { RoleGatingBatch3Checks } from "./RoleGatingBatch3Checks.sol";

/// @title VerifyRoleGatingBatch3
/// @notice Post-execution verifier for batch 3, run against the LIVE chain after the Safe has
///         executed multisend 2 and the trading bundle. Reverts on the first failure:
///           - every batch-3 proxy's EIP-1967 slot holds the exact CREATE3-predicted impl
///             (record cross-checked against the prediction, so a swapped impl is caught)
///           - CashModule setters / DebtManager admin point at the new delegated impls
///           - new modules are default, mirror the old requester status, are LendGateway drivers,
///             carry the liquid withdraw queues; old modules untouched (still default + whitelisted)
///           - registry owners and timelock delays unchanged; ADMIN_ROLE / ADMIN_TIMELOCK_ROLE in place
///           - BYTECODE: every live impl / new module byte-matches a local build of this branch
///             with the same constructor args (address embeds such as UUPS `__self` reconciled)
///
///         Each bytecode check is also exposed on its own (`checkBytecode*`), read from live state
///         only, so test/upgrade-bytecode-verification/VerifyRoleGatingBatch3.t.sol can run them
///         one contract at a time.
///
/// Usage:
///   ENV=mainnet forge script scripts/role-gating-batch3/VerifyRoleGatingBatch3.s.sol --rpc-url $OPTIMISM_RPC
///   ENV=mainnet forge script scripts/role-gating-batch3/VerifyRoleGatingBatch3.s.sol --rpc-url $MAINNET_RPC
contract VerifyRoleGatingBatch3 is RoleGatingBatch3Checks, ContractCodeChecker {
    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");
        if (block.chainid == 10) {
            _assertOpEndState(_readOpLive(), _readOpImpls());
            checkBytecodeCashModule();
            checkBytecodeDebtManager();
            checkBytecodeDataProvider();
            checkBytecodePriceProvider();
            checkBytecodeAcross();
            checkBytecodeEnso();
            checkBytecodeLendGateway();
            checkBytecodeStockWithdrawModule();
            checkBytecodeModules();
            checkBytecodeTradingRoleRegistry();
            checkBytecodeTradingDataProvider();
        } else if (block.chainid == 1) {
            _assertEthEndState(_readEthLive(), _readEthImpls());
            checkBytecodeStockUnwrapper();
            checkBytecodeTradingRoleRegistry();
            checkBytecodeTradingDataProvider();
            checkBytecodePriceProvider();
            checkBytecodeAcross();
            checkBytecodeEnso();
            checkBytecodeTradingLens();
        } else {
            revert("VerifyRoleGatingBatch3: Optimism or Ethereum only");
        }
        console.log("=== Batch-3 verification passed (end state + bytecode) ===");
    }

    // ─────────────────────────────── Optimism cash ───────────────────────────────

    function checkBytecodeCashModule() public {
        OpLive memory l = _readOpLive();
        _match("CashModuleCore", _implOf(l.cashModule), address(new CashModuleCore(l.dataProvider)));
        _match("CashModuleSetters", CashModuleCore(payable(l.cashModule)).getCashModuleSetters(), address(new CashModuleSetters(l.dataProvider)));
    }

    function checkBytecodeDebtManager() public {
        OpLive memory l = _readOpLive();
        _match("DebtManagerCore", _implOf(l.debtManager), address(new DebtManagerCore(l.dataProvider)));
        _match("DebtManagerAdmin", DebtManagerCore(l.debtManager).getDebtManagerAdmin(), address(new DebtManagerAdmin(l.dataProvider)));
    }

    function checkBytecodeLendGateway() public {
        OpLive memory l = _readOpLive();
        address spoke = address(LendGateway(l.lendGateway).spoke());
        _match("LendGateway", _implOf(l.lendGateway), address(new LendGateway(l.dataProvider, spoke)));
    }

    function checkBytecodeStockWithdrawModule() public {
        OpLive memory l = _readOpLive();
        _match("StockWithdrawModule", _implOf(l.stockWithdrawModule), address(new StockWithdrawModule(l.dataProvider)));
    }

    /// @dev The five replacement modules, rebuilt with the exact constructor args the deploy
    ///      script derived from the modules they replaced
    function checkBytecodeModules() public {
        OpLive memory l = _readOpLive();
        OpImpls memory i = _readOpImpls();
        address dp = l.dataProvider;

        for (uint256 k = 0; k < 2; ++k) {
            EtherFiLiquidModule old = EtherFiLiquidModule(payable(i.oldModules[k]));
            (address[] memory assets, address[] memory tellers) = _liquidConfig(old);
            address local = k == 0
                ? address(new EtherFiLiquidModule(assets, tellers, dp, old.weth()))
                : address(new EtherFiLiquidModuleWithReferrer(assets, tellers, dp, old.weth()));
            _match(k == 0 ? "EtherFiLiquidModule" : "EtherFiLiquidModuleWithReferrer", i.modules[k], local);
        }
        {
            (address[] memory assets, StargateModule.AssetConfig[] memory configs) = _stargateConfig(StargateModule(payable(i.oldModules[2])));
            _match("StargateModule", i.modules[2], address(new StargateModule(assets, configs, dp)));
        }
        {
            BeHYPEStakeModule old = BeHYPEStakeModule(i.oldModules[3]);
            _match("BeHYPEStakeModule", i.modules[3], address(new BeHYPEStakeModule(dp, address(old.staker()), old.whype(), old.beHYPE(), old.getRefundGasLimit())));
        }
        {
            (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasConfig(MidasModule(i.oldModules[4]));
            _match("MidasModule", i.modules[4], address(new MidasModule(dp, tokens, deposits, redemptions)));
        }
    }

    // ─────────────────────────────── Ethereum cash ───────────────────────────────

    function checkBytecodeStockUnwrapper() public {
        _match("StockUnwrapper", _implOf(_readEthLive().stockUnwrapper), address(new StockUnwrapper()));
    }

    function checkBytecodeTradingLens() public {
        EthLive memory l = _readEthLive();
        _match("TradingLens", _implOf(l.tradingLens), address(new TradingLens(l.tradingPriceProvider)));
    }

    // ─────────────────────────────── both chains ───────────────────────────────

    /// @dev OP: the cash DataProvider (the trading one is checked separately)
    function checkBytecodeDataProvider() public {
        require(block.chainid == 10, "cash DataProvider is OP-only in batch 3");
        _match("EtherFiDataProvider", _implOf(_readOpLive().dataProvider), address(new EtherFiDataProvider()));
    }

    /// @dev OP: cash PriceProvider; ETH: trading PriceProvider. Both run PriceProviderV2
    function checkBytecodePriceProvider() public {
        address proxy = block.chainid == 10 ? _readOpLive().priceProvider : _readEthLive().tradingPriceProvider;
        _match("PriceProviderV2", _implOf(proxy), address(new PriceProviderV2()));
    }

    function checkBytecodeAcross() public {
        (address proxy, address dp) = _swapModule(true);
        _match("AcrossSwapModule", _implOf(proxy), address(new AcrossSwapModule(dp)));
    }

    function checkBytecodeEnso() public {
        (address proxy, address dp) = _swapModule(false);
        _match("EnsoSwapModule", _implOf(proxy), address(new EnsoSwapModule(dp)));
    }

    function checkBytecodeTradingRoleRegistry() public {
        (address registry, address dp) = _trading();
        _match("trading RoleRegistry", _implOf(registry), address(new RoleRegistry(dp)));
    }

    function checkBytecodeTradingDataProvider() public {
        (, address dp) = _trading();
        _match("trading EtherFiDataProvider", _implOf(dp), address(new EtherFiDataProvider()));
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev On OP Across/Enso are cash proxies; on ETH they belong to the trading stack
    function _swapModule(bool across) internal view returns (address proxy, address dp) {
        if (block.chainid == 10) {
            OpLive memory l = _readOpLive();
            return (across ? l.across : l.enso, l.dataProvider);
        }
        EthLive memory e = _readEthLive();
        return (across ? e.across : e.enso, e.tradingDataProvider);
    }

    function _trading() internal view returns (address registry, address dp) {
        if (block.chainid == 10) {
            OpLive memory l = _readOpLive();
            return (l.tradingRoleRegistry, l.tradingDataProvider);
        }
        EthLive memory e = _readEthLive();
        return (e.tradingRoleRegistry, e.tradingDataProvider);
    }

    /// @dev Address-embed-tolerant match: required for UUPS impls (`__self`) and harmless for the
    ///      immutable modules (no embeds, so it degenerates to exact equality)
    function _match(string memory label, address onchain, address local) internal {
        requireCodeMatchAllowingAddressEmbeds(label, onchain, local);
    }
}
