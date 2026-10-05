// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { StockFeedDeployer } from "./DeployStockProdFeeds.s.sol";
import { StockLendAssets } from "./StockLendAssets.sol";
import { DynamicReserveConfigLike, IAaveOracleLike, IHubConfiguratorLike, IHubLike, ISpokeConfiguratorLike, ISpokeLike, InterestRateDataLike, LendRails, ReserveConfigLike, ReserveLike, SpokeConfigLike, StockLendAsset } from "./StockLendConfig.sol";

/**
 * @title ListStockSummerLend3CPBase
 * @notice Generates the LEND OWNER SAFE (0x082B…E844) bundle that lists a 4626-wrapped xStock's
 *         iToken as a collateral-only reserve on the prod Summer Lend instance on Optimism. The
 *         Owner Safe holds the configurator domain-admin role (400), so every call goes through
 *         the Hub/Spoke configurators — the same path the wSPYx/PAXG listing used.
 *
 *         Three calls, mirroring the iwSPYx collateral-only house style (flat 0% curve, 0%
 *         liquidity fee, 10% liquidation fee, risk premium 0, receiveShares on):
 *           1. HubConfigurator.addAsset(iToken)      — flat IR curve, treasury fee receiver
 *           2. HubConfigurator.addSpoke(Cash Spoke)  — asset.addCap, drawCap 0, active
 *           3. SpokeConfigurator.addReserve          — asset.collateralFactor, shared max
 *              liquidation bonus, on the Deploy*ProdFeeds wrapper/USD feed
 *
 *         Asset and reserve ids are consumed from the live counters (sequential), then the whole
 *         bundle is fork-simulated and the post-state asserted before the JSON is trusted.
 *
 *         PREREQUISITE THAT IS FORK-ONLY HERE: for a brand-new asset, neither its iToken ShadowOFT
 *         nor a relayed wrapper price exists anywhere yet — not even on a clean mainnet fork —
 *         until the cash-mainnet-asset-listing bundles that create them execute.
 *         `_rehearseStockRails()` stands both up on THIS fork, using the real factory/salt/sink,
 *         so `addReserve`'s live-price read below succeeds exactly as it will once the real rails
 *         land. It is fork-only: never called from a broadcast script, and its writes never
 *         become calldata in the bundle below.
 *
 *         EXECUTION ORDER: after Deploy*ProdFeeds (the feeds must exist and price), and before the
 *         Operating Safe OP bundle (which registers the resulting reserve id on the LendGateway).
 */
abstract contract ListStockSummerLend3CPBase is GnosisHelpers, Test, StockFeedDeployer {
    function _asset() internal pure virtual returns (StockLendAsset memory);
    function _outputPath() internal pure virtual returns (string memory);

    function run() public {
        StockLendAsset memory asset = _asset();
        string memory outputPath = _outputPath();

        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _rehearseStockRails(asset); // fork-only: iToken + a relayed sink price must exist to price
        (, address wrapperFeed) = _deployFeeds(true, asset);

        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        IHubLike hub = IHubLike(LendRails.CASH_HUB);
        require(_reserveIdOf(spoke, asset.iToken) == type(uint256).max, "already listed");

        // Ids are assigned sequentially from the live counters, in bundle call order
        uint256 assetId = hub.getAssetCount();
        uint256 reserveId = spoke.getReserveCount();

        _writeBundle(asset, outputPath, wrapperFeed, assetId);
        console.log("Written: %s", outputPath);

        executeGnosisTransactionBundle(outputPath);
        _assertPostState(asset, spoke, hub, wrapperFeed, assetId, reserveId);

        console.log("Simulation passed.");
        console.log("  assetId %s, reserveId %s", assetId, reserveId);
        console.log("  wrapper / USD: %s (8 dec)", IAaveOracleLike(LendRails.AAVE_ORACLE).getReservePrice(reserveId));
    }

    function _writeBundle(StockLendAsset memory asset, string memory outputPath, address wrapperFeed, uint256 assetId) internal {
        // Collateral-only house style: flat 0% curve, no borrow use case
        bytes memory irData = abi.encode(InterestRateDataLike({ optimalUsageRatio: 9900, baseDrawnRate: 0, rateGrowthBeforeOptimal: 0, rateGrowthAfterOptimal: 0 }));

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.LEND_OWNER_SAFE));

        txs = _append(txs, LendRails.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addAsset, (LendRails.CASH_HUB, asset.iToken, LendRails.TREASURY_SPOKE, 0, LendRails.IR_STRATEGY, irData)), false);
        txs = _append(txs, LendRails.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addSpoke, (LendRails.CASH_HUB, LendRails.CASH_SPOKE, assetId, _spokeConfig(asset))), false);
        txs = _append(txs, LendRails.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorLike.addReserve, (LendRails.CASH_SPOKE, LendRails.CASH_HUB, assetId, wrapperFeed, _reserveConfig(), _dynamicConfig(asset))), true);

        vm.createDir("./output", true);
        vm.writeFile(outputPath, txs);
    }

    function _assertPostState(StockLendAsset memory asset, ISpokeLike spoke, IHubLike hub, address wrapperFeed, uint256 assetId, uint256 reserveId) internal view {
        assertEq(hub.getAssetCount(), assetId + 1, "asset count");
        assertEq(spoke.getReserveCount(), reserveId + 1, "reserve count");
        assertEq(spoke.getReserveId(LendRails.CASH_HUB, assetId), reserveId, "reserve id");

        ReserveLike memory reserve = spoke.getReserve(reserveId);
        assertEq(reserve.underlying, asset.iToken, "underlying");
        assertEq(reserve.hub, LendRails.CASH_HUB, "hub");
        assertEq(uint256(reserve.assetId), assetId, "assetId");
        assertEq(uint256(reserve.decimals), 18, "decimals");

        ReserveConfigLike memory config = spoke.getReserveConfig(reserveId);
        assertEq(uint256(config.collateralRisk), LendRails.LEND_COLLATERAL_RISK, "collateralRisk");
        assertFalse(config.paused, "paused");
        assertFalse(config.frozen, "frozen");
        assertFalse(config.borrowable, "borrowable");
        assertTrue(config.receiveSharesEnabled, "receiveShares");

        DynamicReserveConfigLike memory dynamicConfig = spoke.getDynamicReserveConfig(reserveId, reserve.dynamicConfigKey);
        assertEq(uint256(dynamicConfig.collateralFactor), asset.collateralFactor, "collateralFactor");
        assertEq(uint256(dynamicConfig.maxLiquidationBonus), LendRails.LEND_MAX_LIQUIDATION_BONUS, "maxLiquidationBonus");
        assertEq(uint256(dynamicConfig.liquidationFee), LendRails.LEND_LIQUIDATION_FEE, "liquidationFee");

        assertEq(IAaveOracleLike(LendRails.AAVE_ORACLE).getReserveSource(reserveId), wrapperFeed, "price source");
        assertGt(IAaveOracleLike(LendRails.AAVE_ORACLE).getReservePrice(reserveId), 0, "live price");

        SpokeConfigLike memory spokeConfig = hub.getSpokeConfig(assetId, LendRails.CASH_SPOKE);
        assertEq(uint256(spokeConfig.addCap), asset.addCap, "addCap");
        assertEq(uint256(spokeConfig.drawCap), 0, "drawCap");
        assertEq(uint256(spokeConfig.riskPremiumThreshold), 0, "riskPremiumThreshold");
        assertTrue(spokeConfig.active, "active");
        assertFalse(spokeConfig.halted, "halted");
    }

    function _spokeConfig(StockLendAsset memory asset) internal pure returns (SpokeConfigLike memory) {
        return SpokeConfigLike({ addCap: asset.addCap, drawCap: 0, riskPremiumThreshold: 0, active: true, halted: false });
    }

    function _reserveConfig() internal pure returns (ReserveConfigLike memory) {
        return ReserveConfigLike({ collateralRisk: LendRails.LEND_COLLATERAL_RISK, paused: false, frozen: false, borrowable: false, receiveSharesEnabled: true });
    }

    function _dynamicConfig(StockLendAsset memory asset) internal pure returns (DynamicReserveConfigLike memory) {
        return DynamicReserveConfigLike({ collateralFactor: asset.collateralFactor, maxLiquidationBonus: LendRails.LEND_MAX_LIQUIDATION_BONUS, liquidationFee: LendRails.LEND_LIQUIDATION_FEE });
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

/**
 * @title ListQqqxSummerLend3CP
 * @notice iwQQQx's List*SummerLend3CP. See ListStockSummerLend3CPBase for the shared mechanics
 *         and StockLendAssets.wqqqx() for this asset's parameters and rollout-specific notes.
 *
 * Usage:
 *   forge script scripts/stock-listing/ListStockSummerLend3CP.s.sol:ListQqqxSummerLend3CP --rpc-url $OPTIMISM_RPC
 */
contract ListQqqxSummerLend3CP is ListStockSummerLend3CPBase {
    function _asset() internal pure override returns (StockLendAsset memory) {
        return StockLendAssets.wqqqx();
    }

    function _outputPath() internal pure override returns (string memory) {
        return "./output/ListQqqxSummerLend3CP-10.json";
    }
}

/**
 * @title ListTbllxSummerLend3CP
 * @notice iwTBLLx's Lend Owner Safe bundle. Regenerate immediately before signing — the asset and
 *         reserve ids come from live counters.
 */
contract ListTbllxSummerLend3CP is ListStockSummerLend3CPBase {
    function _asset() internal pure override returns (StockLendAsset memory) {
        return StockLendAssets.wtbllx();
    }

    function _outputPath() internal pure override returns (string memory) {
        return "./output/3CP-642-ListTbllxSummerLend3CP-10.json";
    }
}
