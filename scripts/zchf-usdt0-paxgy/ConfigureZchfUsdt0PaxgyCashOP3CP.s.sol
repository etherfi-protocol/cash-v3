// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import {
    DynamicReserveConfigLike,
    IAaveOracleLike,
    IHubConfiguratorLike,
    IHubLike,
    ILendGatewayLike,
    ISpokeConfiguratorLike,
    ISpokeLike,
    InterestRateDataLike,
    ReserveConfigLike,
    SpokeConfigLike
} from "../wspyx-paxg/WspyxPaxgProdConfig.sol";
import { IOracleSinkAdminLike } from "../zchf/ZchfProdConfig.sol";
import { RolloutFeedDeployer } from "./DeployZchfUsdt0PaxgyProdFeeds.s.sol";
import { MockOft } from "./MockOft.sol";
import { ZchfUsdt0PaxgyProd as C } from "./ZchfUsdt0PaxgyProdConfig.sol";

/**
 * @title ConfigureZchfUsdt0PaxgyCashOP3CP
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Optimism bundle for the cash side of the ZCHF +
 *         USDT0 (+ PAXGy once pinned) collateral rollout — everything a Cash Safe needs to hold, be
 *         valued on and borrow against the new Summer Lend reserves:
 *
 *           1.    PriceProviderV2.setTokenConfig([ZCHF, USDT0, …])
 *                   ZCHF  — OracleSink.price(mainnet ZCHF), 6 decimals, sink-enforced window (the live
 *                           iwSPYx / iwTBLLx pattern; CHF is not USD: no stable snap)
 *                   USDT0 — Chainlink USDT / USD, 8 decimals, 2 days, stable snap (the live USDT config)
 *           2..   DebtManager.supportCollateralToken(asset)  — LTV / LT / bonus per asset (PROPOSED)
 *           ..N   LendGateway.setReserveId(asset, reserveId) — mirror the new Summer Lend reserves into
 *                 the gateway registry (reverts ReserveAssetMismatch unless the id really is the asset's)
 *
 *         EXECUTION ORDER: after the aave-v4 timelock listing has EXECUTED (the reserve ids the last
 *         calls register must exist, and DebtManager.supportCollateralToken reads the price). When the
 *         reserves are not yet live on the fork, the simulation rehearses the aave-v4 listing first
 *         (pranking the EtherFiTimelock with the same parameters, rehearsal-deploying any feed that
 *         has no code yet), so this JSON can be generated and rehearsed in one sitting with the rest.
 *
 *         Deliberately NOT in this bundle: LendGateway.setSpendAsset (whether the card may settle a
 *         debit spend in USDT0 is a product / settlement-rails decision), DebtManager.supportBorrowToken
 *         (USDT0 is borrowable on Summer Lend with its draw cap pinned to 0, but a DebtManager borrow token is a
 *         separate product decision; ZCHF / PAXGy are collateral-only everywhere).
 *
 * Usage:
 *   forge script scripts/zchf-usdt0-paxgy/ConfigureZchfUsdt0PaxgyCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigureZchfUsdt0PaxgyCashOP3CP is GnosisHelpers, Test, RolloutFeedDeployer {
    string constant OUTPUT_PATH = "./output/ConfigureZchfUsdt0PaxgyCashOP3CP-10.json";
    string constant REHEARSAL_OUTPUT_PATH = "./output/ConfigureZchfUsdt0PaxgyCashOP3CP-10.rehearsal.json";

    struct Asset {
        string symbol;
        address token;
        PriceProviderV2.Config pp;
        IDebtManager.CollateralTokenConfig dm;
        // Summer Lend mirror of the aave-v4 pins — fork rehearsal of the listing only
        address lendFeed;
        uint40 lendAddCap;
        uint16 lendCollateralFactor;
        uint32 lendMaxLiquidationBonus;
        bool lendBorrowable;
        uint256 lendLiquidityFee;
        InterestRateDataLike lendIr;
    }

    function run() public {
        _generate(OUTPUT_PATH);
    }

    /// @dev Fork-only: the whole bundle with any not-yet-deployed OFT (PAXGy until iPAXGy lands) stood in
    ///      by a mock ERC20, so its leg (composed price, DebtManager config, gateway id) is rehearsed ahead.
    ///      Writes a separate *.rehearsal.json that must never be signed.
    function rehearse() public {
        if (C.PAXGY != address(0) && C.PAXGY.code.length == 0) {
            vm.etch(C.PAXGY, address(new MockOft()).code);
            console.log("  [MOCK] PAXGy OFT stood in at", C.PAXGY);
        }
        _generate(REHEARSAL_OUTPUT_PATH);
    }

    function _generate(string memory outputPath) internal {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        ILendGatewayLike gateway = ILendGatewayLike(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")), ".lendGateway"));

        Asset[] memory assets = _assets();
        for (uint256 i; i < assets.length; ++i) {
            require(!debtManager.isCollateralToken(assets[i].token), string.concat(assets[i].symbol, " already a DebtManager collateral"));
            (bool priced,) = address(pp).staticcall(abi.encodeCall(PriceProviderV2.price, (assets[i].token)));
            require(!priced, string.concat(assets[i].symbol, " already priced by PriceProviderV2"));
        }

        // The Summer Lend reserve ids the last calls register: live once the aave-v4 timelock
        // listing has executed, otherwise rehearsed on the fork
        uint256[] memory reserveIds = _reserveIds(assets);

        _writeBundle(pp, debtManager, gateway, assets, reserveIds, outputPath);
        console.log("Written: %s", outputPath);

        executeGnosisTransactionBundle(outputPath);
        _assertPostState(pp, debtManager, gateway, assets, reserveIds);

        console.log("Simulation passed. PriceProviderV2 prices (6 decimals) / LendGateway reserve ids:");
        for (uint256 i; i < assets.length; ++i) {
            console.log("  %s: %s (reserveId %s)", assets[i].symbol, pp.price(assets[i].token), reserveIds[i]);
        }
    }

    /// @dev The assets of this bundle, in call order. An asset without a pinned token is skipped ([todo]); one
    ///      whose token has no code yet (a predicted OFT) is held ([token]) — rehearse() stands it in.
    function _assets() internal view returns (Asset[] memory assets) {
        Asset[] memory all = new Asset[](3);
        all[0] = Asset({
            symbol: "ZCHF",
            token: C.ZCHF,
            pp: PriceProviderV2.Config({
                oracle: C.ORACLE_SINK,
                priceFunctionCalldata: abi.encodeWithSelector(C.ORACLE_SINK_PRICE_SELECTOR, C.ZCHF_MAINNET),
                isChainlinkType: false,
                oraclePriceDecimals: C.ORACLE_SINK_DECIMALS,
                maxStaleness: 0,
                dataType: PriceProviderV2.ReturnType.Uint256,
                isStableToken: false,
                baseAsset: address(0)
            }),
            dm: IDebtManager.CollateralTokenConfig({ ltv: C.DM_ZCHF_LTV, liquidationThreshold: C.DM_ZCHF_LIQ_THRESHOLD, liquidationBonus: C.DM_ZCHF_LIQ_BONUS }),
            lendFeed: C.LEND_ZCHF_FEED,
            lendAddCap: C.LEND_ZCHF_ADD_CAP,
            lendCollateralFactor: C.LEND_ZCHF_COLLATERAL_FACTOR,
            lendMaxLiquidationBonus: C.LEND_ZCHF_MAX_LIQUIDATION_BONUS,
            lendBorrowable: false,
            lendLiquidityFee: 0,
            lendIr: _flatCurve()
        });
        all[1] = Asset({
            symbol: "USDT0",
            token: C.USDT0,
            pp: PriceProviderV2.Config({
                oracle: C.USDT_USD_AGGREGATOR,
                priceFunctionCalldata: "",
                isChainlinkType: true,
                oraclePriceDecimals: 8,
                maxStaleness: C.USDT_USD_MAX_STALENESS,
                dataType: PriceProviderV2.ReturnType.Int256,
                isStableToken: true,
                baseAsset: address(0)
            }),
            dm: IDebtManager.CollateralTokenConfig({ ltv: C.DM_USDT0_LTV, liquidationThreshold: C.DM_USDT0_LIQ_THRESHOLD, liquidationBonus: C.DM_USDT0_LIQ_BONUS }),
            lendFeed: C.LEND_USDT0_FEED,
            lendAddCap: C.LEND_USDT0_ADD_CAP,
            lendCollateralFactor: C.LEND_USDT0_COLLATERAL_FACTOR,
            lendMaxLiquidationBonus: C.LEND_USDT0_MAX_LIQUIDATION_BONUS,
            lendBorrowable: true,
            lendLiquidityFee: C.LEND_USDT0_LIQUIDITY_FEE,
            lendIr: InterestRateDataLike({ optimalUsageRatio: C.LEND_USDT0_OPTIMAL_USAGE_RATIO, baseDrawnRate: C.LEND_USDT0_BASE_DRAWN_RATE, rateGrowthBeforeOptimal: C.LEND_USDT0_RATE_GROWTH_BEFORE_OPTIMAL, rateGrowthAfterOptimal: C.LEND_USDT0_RATE_GROWTH_AFTER_OPTIMAL })
        });
        all[2] = Asset({
            symbol: "PAXGy",
            token: C.PAXGY,
            pp: PriceProviderV2.Config({
                oracle: C.PAXGY_XAU_RATE_FEED,
                priceFunctionCalldata: "",
                isChainlinkType: true,
                oraclePriceDecimals: 18,
                maxStaleness: C.PAXGY_XAU_MAX_STALENESS,
                dataType: PriceProviderV2.ReturnType.Int256,
                isStableToken: false,
                baseAsset: C.XAU_DENOMINATION // x XAU / USD, the way iwSPYx composes on SPYx
            }),
            dm: IDebtManager.CollateralTokenConfig({ ltv: C.DM_PAXGY_LTV, liquidationThreshold: C.DM_PAXGY_LIQ_THRESHOLD, liquidationBonus: C.DM_PAXGY_LIQ_BONUS }),
            lendFeed: C.LEND_PAXGY_FEED,
            lendAddCap: C.LEND_PAXGY_ADD_CAP,
            lendCollateralFactor: C.LEND_PAXGY_COLLATERAL_FACTOR,
            lendMaxLiquidationBonus: C.LEND_PAXGY_MAX_LIQUIDATION_BONUS,
            lendBorrowable: false,
            lendLiquidityFee: 0,
            lendIr: _flatCurve()
        });

        Asset[] memory kept = new Asset[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (_active(all[i])) kept[n++] = all[i];
        }
        assets = new Asset[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = kept[i];
        }
    }

    function _writeBundle(PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway, Asset[] memory assets, uint256[] memory reserveIds, string memory outputPath) internal {
        (address[] memory tokens, PriceProviderV2.Config[] memory configs) = _priceConfigs(assets);

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, address(pp), abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs), false);
        for (uint256 i; i < assets.length; ++i) {
            txs = _append(txs, address(debtManager), abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, assets[i].token, assets[i].dm), false);
        }
        for (uint256 i; i < assets.length; ++i) {
            txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (assets[i].token, reserveIds[i])), i + 1 == assets.length);
        }

        vm.createDir("./output", true);
        vm.writeFile(outputPath, txs);
    }

    function _assertPostState(PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway, Asset[] memory assets, uint256[] memory reserveIds) internal view {
        if (_needsXau(assets)) {
            PriceProviderV2.Config memory xau = pp.tokenConfig(C.XAU_DENOMINATION);
            assertEq(xau.oracle, C.XAU_USD_AGGREGATOR, "XAU: oracle");
            assertTrue(xau.isChainlinkType, "XAU: isChainlinkType");
            assertEq(uint256(xau.oraclePriceDecimals), 8, "XAU: decimals");
            assertEq(uint256(xau.maxStaleness), uint256(C.XAU_USD_MAX_STALENESS), "XAU: maxStaleness");
            assertEq(xau.baseAsset, address(0), "XAU: baseAsset");
            assertGt(pp.price(C.XAU_DENOMINATION), 1000e6, "XAU / USD: implausible");
        }
        for (uint256 i; i < assets.length; ++i) {
            Asset memory a = assets[i];
            PriceProviderV2.Config memory config = pp.tokenConfig(a.token);
            assertEq(config.oracle, a.pp.oracle, string.concat(a.symbol, ": oracle"));
            assertEq(config.priceFunctionCalldata, a.pp.priceFunctionCalldata, string.concat(a.symbol, ": priceFunctionCalldata"));
            assertEq(config.isChainlinkType, a.pp.isChainlinkType, string.concat(a.symbol, ": isChainlinkType"));
            assertEq(uint256(config.oraclePriceDecimals), uint256(a.pp.oraclePriceDecimals), string.concat(a.symbol, ": oraclePriceDecimals"));
            assertEq(uint256(config.maxStaleness), uint256(a.pp.maxStaleness), string.concat(a.symbol, ": maxStaleness"));
            assertEq(uint256(config.dataType), uint256(a.pp.dataType), string.concat(a.symbol, ": dataType"));
            assertEq(config.isStableToken, a.pp.isStableToken, string.concat(a.symbol, ": isStableToken"));
            assertEq(config.baseAsset, a.pp.baseAsset, string.concat(a.symbol, ": baseAsset"));

            uint256 price = pp.price(a.token);
            assertGt(price, 0, string.concat(a.symbol, ": no price"));
            if (a.token == C.ZCHF) {
                (, int256 sinkAnswer,,,) = IOracleSinkAdminLike(C.ORACLE_SINK).latestRoundData(C.ZCHF_MAINNET);
                assertEq(price, uint256(sinkAnswer), "ZCHF: provider price != sink price");
            }
            if (a.pp.isStableToken) assertEq(price, 1e6, string.concat(a.symbol, ": stable snap"));
            // both sides of the house value the asset alike (Summer Lend 8 decimals vs provider 6)
            uint256 lendPrice = IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(reserveIds[i]);
            assertApproxEqRel(price * 100, lendPrice, 0.01e18, string.concat(a.symbol, ": provider vs Summer Lend price > 1% apart"));

            assertTrue(debtManager.isCollateralToken(a.token), string.concat(a.symbol, ": not a collateral token"));
            IDebtManager.CollateralTokenConfig memory dm = debtManager.collateralTokenConfig(a.token);
            assertEq(uint256(dm.ltv), uint256(a.dm.ltv), string.concat(a.symbol, ": ltv"));
            assertEq(uint256(dm.liquidationThreshold), uint256(a.dm.liquidationThreshold), string.concat(a.symbol, ": liquidationThreshold"));
            assertEq(uint256(dm.liquidationBonus), uint256(a.dm.liquidationBonus), string.concat(a.symbol, ": liquidationBonus"));
            assertFalse(debtManager.isBorrowToken(a.token), string.concat(a.symbol, ": must stay collateral-only"));

            assertEq(gateway.reserveIdOf(a.token), reserveIds[i], string.concat(a.symbol, ": gateway reserve id"));
        }
    }

    /// @dev The Summer Lend reserve ids of the assets; rehearses the aave-v4 timelock listing on the
    ///      fork for any not yet listed live (same parameters as aave-v4 AaveV4EtherfiCash.sol).
    function _reserveIds(Asset[] memory assets) internal returns (uint256[] memory ids) {
        ISpokeLike spoke = ISpokeLike(C.CASH_SPOKE);
        ids = new uint256[](assets.length);
        bool rehearsed;
        for (uint256 i; i < assets.length; ++i) {
            ids[i] = _reserveIdOf(spoke, assets[i].token);
            if (ids[i] != type(uint256).max) continue;
            if (!rehearsed) console.log("Reserves not yet listed live; rehearsing the aave-v4 timelock listing on the fork");
            rehearsed = true;
            _rehearseListing(assets[i]);
            ids[i] = _reserveIdOf(spoke, assets[i].token);
            require(ids[i] != type(uint256).max, string.concat(assets[i].symbol, ": rehearsal did not list the reserve"));
        }
    }

    /// @dev Fork-only: the aave-v4 operation of one asset (addAsset -> addSpoke -> addReserve), sent by
    ///      the EtherFiTimelock. Feeds without code yet are rehearsal-deployed first.
    function _rehearseListing(Asset memory a) internal {
        require(a.lendFeed != address(0), string.concat(a.symbol, ": no Summer Lend feed pinned"));
        if (a.lendFeed.code.length == 0) _deployAll(true); // rehearsal-deploys every rollout feed not live yet
        require(a.lendFeed.code.length != 0, string.concat(a.symbol, ": Summer Lend feed has no code"));

        uint256 assetId = IHubLike(C.CASH_HUB).getAssetCount();
        vm.startPrank(C.LEND_TIMELOCK);
        IHubConfiguratorLike(C.HUB_CONFIGURATOR).addAsset(
            C.CASH_HUB, a.token, C.TREASURY_SPOKE, a.lendLiquidityFee, C.IR_STRATEGY, abi.encode(a.lendIr)
        );
        IHubConfiguratorLike(C.HUB_CONFIGURATOR).addSpoke(C.CASH_HUB, C.CASH_SPOKE, assetId, SpokeConfigLike({ addCap: a.lendAddCap, drawCap: 0, riskPremiumThreshold: 0, active: true, halted: false }));
        ISpokeConfiguratorLike(C.SPOKE_CONFIGURATOR).addReserve(
            C.CASH_SPOKE,
            C.CASH_HUB,
            assetId,
            a.lendFeed,
            ReserveConfigLike({ collateralRisk: 0, paused: false, frozen: false, borrowable: a.lendBorrowable, receiveSharesEnabled: true }),
            DynamicReserveConfigLike({ collateralFactor: a.lendCollateralFactor, maxLiquidationBonus: a.lendMaxLiquidationBonus, liquidationFee: C.LEND_LIQUIDATION_FEE })
        );
        vm.stopPrank();
        console.log("  [REHEARSAL] %s listed on Summer Lend as assetId %s", a.symbol, assetId);
    }

    /// @dev The setTokenConfig payload: the XAU / USD base entry first when an asset composes on it
    ///      (PriceProviderV2 resolves a base asset by its own token config), then the assets.
    function _priceConfigs(Asset[] memory assets) internal pure returns (address[] memory tokens, PriceProviderV2.Config[] memory configs) {
        uint256 extra = _needsXau(assets) ? 1 : 0;
        tokens = new address[](assets.length + extra);
        configs = new PriceProviderV2.Config[](assets.length + extra);
        if (extra == 1) {
            tokens[0] = C.XAU_DENOMINATION;
            configs[0] = PriceProviderV2.Config({
                oracle: C.XAU_USD_AGGREGATOR,
                priceFunctionCalldata: "",
                isChainlinkType: true,
                oraclePriceDecimals: 8,
                maxStaleness: C.XAU_USD_MAX_STALENESS,
                dataType: PriceProviderV2.ReturnType.Int256,
                isStableToken: false,
                baseAsset: address(0)
            });
        }
        for (uint256 i; i < assets.length; ++i) {
            tokens[i + extra] = assets[i].token;
            configs[i + extra] = assets[i].pp;
        }
    }

    function _needsXau(Asset[] memory assets) internal pure returns (bool) {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i].pp.baseAsset == C.XAU_DENOMINATION) return true;
        }
        return false;
    }

    function _active(Asset memory a) internal view returns (bool) {
        if (a.token == address(0)) {
            console.log(string.concat("  [todo] ", a.symbol, ": token not pinned - skipped"));
            return false;
        }
        if (a.token.code.length == 0) {
            console.log(string.concat("  [token] ", a.symbol, ": no code at its token yet (OFT not deployed) - held; rehearse() stands it in"));
            return false;
        }
        return true;
    }

    function _flatCurve() internal pure returns (InterestRateDataLike memory) {
        return InterestRateDataLike({ optimalUsageRatio: C.LEND_COLLATERAL_ONLY_OPTIMAL_USAGE_RATIO, baseDrawnRate: 0, rateGrowthBeforeOptimal: 0, rateGrowthAfterOptimal: 0 });
    }

    function _reserveIdOf(ISpokeLike spoke, address token) internal view returns (uint256) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        return type(uint256).max;
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
