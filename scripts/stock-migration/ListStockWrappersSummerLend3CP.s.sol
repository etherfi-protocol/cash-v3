// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { DynamicReserveConfigLike, IAaveOracleLike, IHubConfiguratorLike, IHubLike, ISpokeConfiguratorLike, ISpokeLike, InterestRateDataLike, LendRails, ReserveConfigLike, ReserveLike, SpokeConfigLike } from "../stock-listing/StockLendConfig.sol";
import { StockMigration3CPBase } from "./StockMigration3CPBase.sol";
import { MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title ListStockWrappersSummerLend3CP
 * @notice TIMELOCK SAFE bundles: list wSPYx, wQQQx and wTBLLx as collateral-only reserves on the prod
 *         Summer Lend instance, priced at 1 wei. The configurator roles sit with the 24h lend timelock, so
 *         this writes two bundles: a scheduleBatch now and an executeBatch after the delay. Every risk
 *         parameter (collateral factor, liquidation bonus and fee, collateral risk, add cap) is copied from
 *         the mirror reserve it replaces, read live at generation time, so the two reserves differ only in
 *         underlying and price source.
 *
 *         At 1 wei the reserves are open for supply but carry no borrowing power, which lets the lend
 *         sweep move every safe's wrapper in before the flip switches the price sources.
 *
 *         One batch of nine calls, three per stock: HubConfigurator.addAsset, HubConfigurator.addSpoke,
 *         SpokeConfigurator.addReserve. The batch lists all three or none. Asset ids come from the live
 *         counters, so nothing else may be listed on the instance between schedule and execute; if it is,
 *         the Timelock Safe cancels and this is regenerated.
 *
 * Usage:
 *   forge script scripts/stock-migration/ListStockWrappersSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC -vvv
 */
contract ListStockWrappersSummerLend3CP is StockMigration3CPBase {
    string constant SCHEDULE = "./output/ListStockWrappersSummerLend3CP-schedule-10.json";
    string constant EXECUTE = "./output/ListStockWrappersSummerLend3CP-execute-10.json";

    function run() public {
        _requireOptimismProd();
        MigrationFeeds memory feeds = _deployMigrationFeeds(true);

        MigratedStock[] memory stocks = StockMigration.all();
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        IHubLike hub = IHubLike(LendRails.CASH_HUB);
        for (uint256 i = 0; i < stocks.length; ++i) {
            require(_reserveIdOf(stocks[i].wrapper) == type(uint256).max, string.concat(stocks[i].symbol, ": wrapper already listed"));
            require(spoke.getReserve(stocks[i].oldReserveId).underlying == stocks[i].iToken, string.concat(stocks[i].symbol, ": old reserve id does not hold the mirror token"));
        }

        uint256 firstAssetId = hub.getAssetCount();
        uint256 firstReserveId = spoke.getReserveCount();

        // Collateral-only house style for the hub asset: flat 0% curve, no borrow use case.
        address[] memory targets = new address[](stocks.length * 3);
        bytes[] memory payloads = new bytes[](stocks.length * 3);
        for (uint256 i = 0; i < stocks.length; ++i) {
            targets[3 * i] = LendRails.HUB_CONFIGURATOR;
            payloads[3 * i] = _addAssetCall(stocks[i].wrapper);
            targets[3 * i + 1] = LendRails.HUB_CONFIGURATOR;
            payloads[3 * i + 1] = _addSpokeCall(stocks[i], firstAssetId + i);
            targets[3 * i + 2] = LendRails.SPOKE_CONFIGURATOR;
            payloads[3 * i + 2] = _addReserveCall(stocks[i], firstAssetId + i, feeds.oneWei8);
        }
        _writeTimelockBundles(SCHEDULE, EXECUTE, StockMigration.LIST_SALT, targets, payloads);

        for (uint256 i = 0; i < stocks.length; ++i) {
            _assertListed(stocks[i], spoke, hub, feeds.oneWei8, firstAssetId + i, firstReserveId + i);
            console.log(string.concat("  ", stocks[i].symbol, " wrapper listed: assetId ", vm.toString(firstAssetId + i), ", reserveId ", vm.toString(firstReserveId + i)));
        }
        console.log("Simulation passed.");
    }

    function _addAssetCall(address wrapper) internal pure returns (bytes memory) {
        bytes memory irData = abi.encode(InterestRateDataLike({ optimalUsageRatio: 9900, baseDrawnRate: 0, rateGrowthBeforeOptimal: 0, rateGrowthAfterOptimal: 0 }));
        return abi.encodeCall(IHubConfiguratorLike.addAsset, (LendRails.CASH_HUB, wrapper, LendRails.TREASURY_SPOKE, 0, LendRails.IR_STRATEGY, irData));
    }

    function _addSpokeCall(MigratedStock memory s, uint256 assetId) internal view returns (bytes memory) {
        uint256 oldAssetId = ISpokeLike(LendRails.CASH_SPOKE).getReserve(s.oldReserveId).assetId;
        SpokeConfigLike memory spokeConfig = IHubLike(LendRails.CASH_HUB).getSpokeConfig(oldAssetId, LendRails.CASH_SPOKE);
        return abi.encodeCall(IHubConfiguratorLike.addSpoke, (LendRails.CASH_HUB, LendRails.CASH_SPOKE, assetId, spokeConfig));
    }

    function _addReserveCall(MigratedStock memory s, uint256 assetId, address oneWei8) internal view returns (bytes memory) {
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        ReserveConfigLike memory config = spoke.getReserveConfig(s.oldReserveId);
        config.frozen = false;
        config.paused = false;
        DynamicReserveConfigLike memory dynamic = spoke.getDynamicReserveConfig(s.oldReserveId, spoke.getReserve(s.oldReserveId).dynamicConfigKey);
        return abi.encodeCall(ISpokeConfiguratorLike.addReserve, (LendRails.CASH_SPOKE, LendRails.CASH_HUB, assetId, oneWei8, config, dynamic));
    }

    function _assertListed(MigratedStock memory s, ISpokeLike spoke, IHubLike hub, address oneWei8, uint256 assetId, uint256 reserveId) internal view {
        ReserveLike memory reserve = spoke.getReserve(reserveId);
        assertEq(reserve.underlying, s.wrapper, "underlying");
        assertEq(reserve.hub, LendRails.CASH_HUB, "hub");
        assertEq(uint256(reserve.assetId), assetId, "assetId");
        assertEq(uint256(reserve.decimals), 18, "decimals");
        assertEq(IAaveOracleLike(LendRails.AAVE_ORACLE).getReserveSource(reserveId), oneWei8, "price source");
        assertEq(IAaveOracleLike(LendRails.AAVE_ORACLE).getReservePrice(reserveId), 1, "placeholder price");

        _assertConfigsMatchMirror(s, spoke, reserveId, reserve.dynamicConfigKey);
        _assertSpokeConfigMatchesMirror(s, spoke, hub, assetId);
    }

    function _assertConfigsMatchMirror(MigratedStock memory s, ISpokeLike spoke, uint256 reserveId, uint32 dynamicConfigKey) internal view {
        ReserveConfigLike memory config = spoke.getReserveConfig(reserveId);
        ReserveConfigLike memory oldConfig = spoke.getReserveConfig(s.oldReserveId);
        assertEq(uint256(config.collateralRisk), uint256(oldConfig.collateralRisk), "collateralRisk");
        assertFalse(config.paused, "paused");
        assertFalse(config.frozen, "frozen");
        assertFalse(config.borrowable, "borrowable");
        assertEq(config.receiveSharesEnabled, oldConfig.receiveSharesEnabled, "receiveShares");

        DynamicReserveConfigLike memory dynamic = spoke.getDynamicReserveConfig(reserveId, dynamicConfigKey);
        DynamicReserveConfigLike memory oldDynamic = spoke.getDynamicReserveConfig(s.oldReserveId, spoke.getReserve(s.oldReserveId).dynamicConfigKey);
        assertEq(uint256(dynamic.collateralFactor), uint256(oldDynamic.collateralFactor), "collateralFactor");
        assertEq(uint256(dynamic.maxLiquidationBonus), uint256(oldDynamic.maxLiquidationBonus), "maxLiquidationBonus");
        assertEq(uint256(dynamic.liquidationFee), uint256(oldDynamic.liquidationFee), "liquidationFee");
    }

    function _assertSpokeConfigMatchesMirror(MigratedStock memory s, ISpokeLike spoke, IHubLike hub, uint256 assetId) internal view {
        SpokeConfigLike memory spokeConfig = hub.getSpokeConfig(assetId, LendRails.CASH_SPOKE);
        SpokeConfigLike memory oldSpokeConfig = hub.getSpokeConfig(spoke.getReserve(s.oldReserveId).assetId, LendRails.CASH_SPOKE);
        assertEq(uint256(spokeConfig.addCap), uint256(oldSpokeConfig.addCap), "addCap");
        assertEq(uint256(spokeConfig.drawCap), 0, "drawCap");
        assertTrue(spokeConfig.active, "active");
        assertFalse(spokeConfig.halted, "halted");
    }
}

/// @dev The wrapper reserve ids, for the bundles that follow the listing. The listing is one atomic timelock
///      batch, so either all three wrappers are live or none are; with none, the listing is rehearsed on the fork.
abstract contract StockWrapperReserveIds is StockMigration3CPBase {
    function _newReserveIds(MigratedStock[] memory stocks) internal returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](stocks.length);
        uint256 listed;
        for (uint256 i = 0; i < stocks.length; ++i) {
            ids[i] = _reserveIdOf(stocks[i].wrapper);
            if (ids[i] != type(uint256).max) ++listed;
        }
        if (listed == stocks.length) return ids;
        require(listed == 0, "only some wrappers are listed; the listing batch should land all three at once");

        console.log("Wrappers not yet listed live; rehearsing the listing on the fork");
        new ListStockWrappersSummerLend3CP().run();
        for (uint256 i = 0; i < stocks.length; ++i) {
            ids[i] = _reserveIdOf(stocks[i].wrapper);
            require(ids[i] != type(uint256).max, "listing did not list the wrapper");
        }
        return ids;
    }
}
