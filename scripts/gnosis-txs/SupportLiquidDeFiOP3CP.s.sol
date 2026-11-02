// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title SupportLiquidDeFiOP3CP
 * @notice Lists Liquid Bold (symbol liquidDeFi, a Midas vault token) on Optimism prod as collateral and as a
 *         debit-spend asset on both engines, DebtManager (legacy) and LendGateway (COR-2055, Notion LIST-5).
 *         Two Safe bundles from the CashController Safe:
 *
 *           Step 1 (day 0): schedule one admin timelock (8h) batch:
 *               MidasModule.addMidasVaults (deposit + redemption vault)
 *               SettlementDispatcherV2.setMidasRedemptionVault on Rain, Reap, Pix, CardOrder
 *             Does not depend on the Aave listing, so it can go out before reserve 29 exists.
 *           Step 2 (>= 8h after step 1 executes, and after Aave lists reserve 29 for liquidDeFi):
 *             1. admin timelock executeBatch
 *             2. PriceProviderV2.setTokenConfig   -> liquidDeFi/USD Midas feed, same shape as liquidRWA
 *             3. DebtManager.supportCollateralToken (LTV 64%, liquidation threshold 75%, bonus 7.5%)
 *             4. DebtManager.supportBorrowToken   (apy 1, minShares max: legacy debit spend only, same as liquidEUR;
 *                                                  nobody can meet minShares, so it cannot be supplied or borrowed)
 *             5. CashModule.configureWithdrawAssets ([liquidDeFi] => true)
 *             6. LendGateway.setReserveId(liquidDeFi, 29)
 *             7. LendGateway.setSpendAsset(liquidDeFi, true)
 *             Calls 2-7 need ADMIN_ROLE, which the Safe holds directly. PriceProvider goes before DebtManager
 *             because supportCollateralToken reverts on a zero price. Spend turns on in the same bundle that
 *             executes the timelock batch, so it is never live before every dispatcher can redeem liquidDeFi.
 *
 *         Credit spend stays off on both engines: the DebtManager borrow token cannot be supplied (minShares max),
 *         and the gateway credit path also requires the Aave reserve to be borrowable (Notion borrow cap 0).
 *         Not included: MidasLiquifierModule.setPair (repaying debt with liquidDeFi).
 *
 * @dev The timelock salt is specific to this listing so the operation id is unique; TimelockController keeps an
 *      id `isOperation` forever, so a reused salt could never be re-scheduled.
 *      If Aave has not listed reserve 29 on the fork, the simulation mocks Spoke.getReserve(29) so step 2 can be
 *      exercised. The real step 2 bundle is unchanged; it will revert on-chain until the reserve exists.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates both steps on the fork):
 *   forge script scripts/gnosis-txs/SupportLiquidDeFiOP3CP.s.sol --rpc-url $OPTIMISM_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 */
contract SupportLiquidDeFiOP3CP is Utils, GnosisHelpers {
    using stdJson for string;

    address constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 constant ADMIN_DELAY = 8 hours;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant SALT_ADMIN = keccak256("SupportLiquidDeFi.midasVaults");

    // ─── Token, Midas vaults and feed (COR-2055 / Notion LIST-5) ───────────────
    address constant LIQUID_DEFI = 0x4299b11815F25DB50fC56CD8a1C24cCCDD2AEECe;
    address constant LIQUID_DEFI_DEPOSIT_VAULT = 0x877f5D9fE35A0A2aFDD4539b992c0edD33d476f4; // depositVault
    address constant LIQUID_DEFI_REDEMPTION_VAULT = 0x1BCb96E1D4CBf07334f9bDdF2f1F872ED00D504b; // redemptionVaultSwapper
    address constant LIQUID_DEFI_USD_FEED = 0xF354e713E9DF3CfBEbAD1221D779F6C4ca198a57; // Midas customFeed, "liquidDeFi/USD", 8 dec
    uint24 constant FEED_MAX_STALENESS = 7 days; // same as liquidRWA

    // ─── Aave v4 reserve ───────────────────────────────────────────────────────
    uint256 constant RESERVE_ID = 29;

    // ─── Risk parameters (Notion LIST-5, risk signed off 2026-11-01) ───────────
    uint80 constant LTV = 64e18; // 64%
    uint80 constant LIQUIDATION_THRESHOLD = 75e18; // 75%
    uint96 constant LIQUIDATION_BONUS = 7.5e18; // 7.5%

    // ─── DebtManager borrow-token config: debit spend only (same as liquidEUR) ─
    uint64 constant BORROW_APY_PER_SECOND = 1;
    uint128 constant MIN_BORROW_SHARES = type(uint128).max;

    RoleRegistry roleRegistry;
    MidasModule midasModule;
    PriceProviderV2 priceProvider;
    IDebtManager debtManager;
    ICashModule cashModule;
    LendGateway gateway;
    IAaveV4Spoke spoke;
    address[4] dispatchers;

    address[] adminTargets;
    bytes[] adminPayloads;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        _load();
        _checkPreconditions();
        _buildAdminBatch();

        string memory step1 = _writeBundle("step1-schedule", string.concat(_getGnosisHeader("10", addressToHex(SAFE)), _scheduleTx(true)));
        string memory step2 = _writeBundle("step2-execute", _step2Txs());

        _simulate(step1, step2);
    }

    function _step2Txs() internal view returns (string memory txs) {
        txs = string.concat(_getGnosisHeader("10", addressToHex(SAFE)), _executeTx(false));
        txs = string.concat(txs, _tx(address(priceProvider), abi.encodeCall(PriceProviderV2.setTokenConfig, (_tokens(), _priceConfigs())), false));
        txs = string.concat(txs, _tx(address(debtManager), abi.encodeCall(IDebtManager.supportCollateralToken, (LIQUID_DEFI, _collateralConfig())), false));
        txs = string.concat(txs, _tx(address(debtManager), abi.encodeCall(IDebtManager.supportBorrowToken, (LIQUID_DEFI, BORROW_APY_PER_SECOND, MIN_BORROW_SHARES)), false));
        txs = string.concat(txs, _tx(address(cashModule), abi.encodeCall(ICashModule.configureWithdrawAssets, (_tokens(), _trues())), false));
        txs = string.concat(txs, _tx(address(gateway), abi.encodeCall(LendGateway.setReserveId, (LIQUID_DEFI, RESERVE_ID)), false));
        txs = string.concat(txs, _tx(address(gateway), abi.encodeCall(LendGateway.setSpendAsset, (LIQUID_DEFI, true)), true));
    }

    function _load() internal {
        string memory d = readDeploymentFile();
        roleRegistry = RoleRegistry(d.readAddress(".addresses.RoleRegistry"));
        midasModule = MidasModule(d.readAddress(".addresses.MidasModule"));
        priceProvider = PriceProviderV2(d.readAddress(".addresses.PriceProvider"));
        debtManager = IDebtManager(d.readAddress(".addresses.DebtManager"));
        cashModule = ICashModule(d.readAddress(".addresses.CashModule"));
        gateway = LendGateway(d.readAddress(".addresses.LendGateway"));
        spoke = IAaveV4Spoke(address(gateway.spoke()));
        dispatchers = [d.readAddress(".addresses.SettlementDispatcherRain"), d.readAddress(".addresses.SettlementDispatcherReap"), d.readAddress(".addresses.SettlementDispatcherPix"), d.readAddress(".addresses.SettlementDispatcherCardOrder")];
    }

    function _checkPreconditions() internal view {
        // Governance: ADMIN_ROLE calls come straight from the Safe, addMidasVaults goes through the 8h admin timelock
        require(roleRegistry.hasRole(roleRegistry.ADMIN_ROLE(), SAFE), "Safe lacks ADMIN_ROLE");
        require(roleRegistry.hasRole(roleRegistry.ADMIN_TIMELOCK_ROLE(), ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        EtherFiTimelock tl = EtherFiTimelock(payable(ADMIN_TIMELOCK));
        require(keccak256(ADMIN_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");
        require(tl.getMinDelay() == ADMIN_DELAY, "admin timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), SAFE), "Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), SAFE) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Safe is not an executor");

        // Inputs: both vaults point at the token, the feed is live and priced
        require(IMidasVaultToken(LIQUID_DEFI_DEPOSIT_VAULT).mToken() == LIQUID_DEFI, "deposit vault mToken mismatch");
        require(IMidasVaultToken(LIQUID_DEFI_REDEMPTION_VAULT).mToken() == LIQUID_DEFI, "redemption vault mToken mismatch");
        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(LIQUID_DEFI_USD_FEED).latestRoundData();
        require(IChainlinkFeed(LIQUID_DEFI_USD_FEED).decimals() == 8, "feed decimals != 8");
        require(answer > 0, "feed answer <= 0");
        require(block.timestamp - updatedAt <= FEED_MAX_STALENESS, "feed already stale");

        // State now: nothing configured for liquidDeFi yet
        (address dv, address rv) = midasModule.vaults(LIQUID_DEFI);
        require(dv == address(0) && rv == address(0), "Midas vaults already set");
        require(priceProvider.tokenConfig(LIQUID_DEFI).oracle == address(0), "PriceProvider config already set");
        require(!debtManager.isCollateralToken(LIQUID_DEFI), "already a DebtManager collateral token");
        require(!debtManager.isBorrowToken(LIQUID_DEFI), "already a DebtManager borrow token");
        require(!_isWithdrawAsset(), "already a withdraw asset");
        require(!gateway.isRegistered(LIQUID_DEFI), "already a gateway reserve");
        require(!gateway.isSpendAsset(LIQUID_DEFI), "already a gateway spend asset");
        for (uint256 i = 0; i < 4; i++) {
            require(SettlementDispatcherV2(payable(dispatchers[i])).getMidasRedemptionVault(LIQUID_DEFI) == address(0), "dispatcher vault already set");
        }
    }

    function _buildAdminBatch() internal {
        address[] memory tokens = _tokens();
        address[] memory depositVaults = new address[](1);
        depositVaults[0] = LIQUID_DEFI_DEPOSIT_VAULT;
        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = LIQUID_DEFI_REDEMPTION_VAULT;

        adminTargets.push(address(midasModule));
        adminPayloads.push(abi.encodeCall(MidasModule.addMidasVaults, (tokens, depositVaults, redemptionVaults)));
        for (uint256 i = 0; i < 4; i++) {
            adminTargets.push(dispatchers[i]);
            adminPayloads.push(abi.encodeCall(SettlementDispatcherV2.setMidasRedemptionVault, (LIQUID_DEFI, LIQUID_DEFI_REDEMPTION_VAULT)));
        }

        require(!_isOperation(), "admin batch already scheduled");
    }

    // ── Call data ──────────────────────────────────────────────────────────────

    function _tokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = LIQUID_DEFI;
    }

    function _trues() internal pure returns (bool[] memory flags) {
        flags = new bool[](1);
        flags[0] = true;
    }

    function _priceConfigs() internal pure returns (PriceProviderV2.Config[] memory configs) {
        configs = new PriceProviderV2.Config[](1);
        configs[0] = PriceProviderV2.Config({ oracle: LIQUID_DEFI_USD_FEED, priceFunctionCalldata: "", isChainlinkType: true, oraclePriceDecimals: 8, maxStaleness: FEED_MAX_STALENESS, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
    }

    function _collateralConfig() internal pure returns (IDebtManager.CollateralTokenConfig memory) {
        return IDebtManager.CollateralTokenConfig({ ltv: LTV, liquidationThreshold: LIQUIDATION_THRESHOLD, liquidationBonus: LIQUIDATION_BONUS });
    }

    // ── Bundle encoding ────────────────────────────────────────────────────────

    function _scheduleTx(bool isLast) internal view returns (string memory) {
        bytes memory data = abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", adminTargets, new uint256[](adminTargets.length), adminPayloads, TL_PREDECESSOR, SALT_ADMIN, ADMIN_DELAY);
        return _tx(ADMIN_TIMELOCK, data, isLast);
    }

    function _executeTx(bool isLast) internal view returns (string memory) {
        bytes memory data = abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", adminTargets, new uint256[](adminTargets.length), adminPayloads, TL_PREDECESSOR, SALT_ADMIN);
        return _tx(ADMIN_TIMELOCK, data, isLast);
    }

    function _tx(address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/SupportLiquidDeFiOP3CP-10-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
        return path;
    }

    function _isOperation() internal view returns (bool) {
        bytes32 id = EtherFiTimelock(payable(ADMIN_TIMELOCK)).hashOperationBatch(adminTargets, new uint256[](adminTargets.length), adminPayloads, TL_PREDECESSOR, SALT_ADMIN);
        return EtherFiTimelock(payable(ADMIN_TIMELOCK)).isOperation(id);
    }

    function _isWithdrawAsset() internal view returns (bool) {
        address[] memory assets = cashModule.getWhitelistedWithdrawAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == LIQUID_DEFI) return true;
        }
        return false;
    }

    // ── Fork simulation: both steps with end-state asserts ─────────────────────

    function _simulate(string memory step1, string memory step2) internal {
        console.log("=== Step 1: schedule addMidasVaults on the admin timelock ===");
        executeGnosisTransactionBundle(step1);
        require(_isOperation(), "admin batch not scheduled");
        require(!gateway.isSpendAsset(LIQUID_DEFI) && !debtManager.isBorrowToken(LIQUID_DEFI), "spend must stay off after step 1");

        console.log("=== Warp 8h, step 2: execute + PriceProvider, DebtManager, CashModule, LendGateway ===");
        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        _ensureReserveListed();
        executeGnosisTransactionBundle(step2);

        (address dv, address rv) = midasModule.vaults(LIQUID_DEFI);
        require(dv == LIQUID_DEFI_DEPOSIT_VAULT && rv == LIQUID_DEFI_REDEMPTION_VAULT, "Midas vaults mismatch");
        require(priceProvider.price(LIQUID_DEFI) > 0, "price is zero");
        require(debtManager.isCollateralToken(LIQUID_DEFI), "not a DebtManager collateral token");
        IDebtManager.CollateralTokenConfig memory cfg = debtManager.collateralTokenConfig(LIQUID_DEFI);
        require(cfg.ltv == LTV && cfg.liquidationThreshold == LIQUIDATION_THRESHOLD && cfg.liquidationBonus == LIQUIDATION_BONUS, "collateral config mismatch");
        require(_isWithdrawAsset(), "not a withdraw asset");
        require(gateway.isRegistered(LIQUID_DEFI) && gateway.reserveIdOf(LIQUID_DEFI) == RESERVE_ID, "gateway reserve mismatch");
        require(debtManager.isBorrowToken(LIQUID_DEFI), "not a DebtManager borrow token");
        require(debtManager.borrowApyPerSecond(LIQUID_DEFI) == BORROW_APY_PER_SECOND, "borrow apy mismatch");
        require(gateway.isSpendAsset(LIQUID_DEFI), "not a gateway spend asset");
        for (uint256 i = 0; i < 4; i++) {
            require(SettlementDispatcherV2(payable(dispatchers[i])).getMidasRedemptionVault(LIQUID_DEFI) == LIQUID_DEFI_REDEMPTION_VAULT, "dispatcher vault not set");
        }
        console.log("Simulation OK: liquidDeFi is a Midas vault, priced, collateral, debit-spendable on DebtManager and gateway reserve", RESERVE_ID);
    }

    /// @dev Uses the real reserve when Aave has listed it; otherwise mocks getReserve(RESERVE_ID) for the fork only
    function _ensureReserveListed() internal {
        if (spoke.getReserveCount() > RESERVE_ID) {
            require(spoke.getReserve(RESERVE_ID).underlying == LIQUID_DEFI, "Spoke reserve 29 is not liquidDeFi");
            console.log("Spoke reserve 29 is listed: using real state");
            return;
        }
        console.log("WARNING: Spoke reserve 29 not listed yet; mocking getReserve(29) for the simulation only");
        IAaveV4Spoke.Reserve memory r;
        r.underlying = LIQUID_DEFI;
        r.decimals = 18;
        vm.mockCall(address(spoke), abi.encodeCall(IAaveV4Spoke.getReserve, (RESERVE_ID)), abi.encode(r));
    }
}

interface IMidasVaultToken {
    function mToken() external view returns (address);
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
