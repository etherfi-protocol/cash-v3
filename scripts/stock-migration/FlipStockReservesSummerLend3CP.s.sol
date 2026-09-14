// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { IAaveOracleLike, ISpokeLike, LendRails } from "../stock-listing/StockLendConfig.sol";
import { StockMigration3CPBase } from "./StockMigration3CPBase.sol";
import { ISpokeConfiguratorMigrationLike, MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title FlipStockReservesSummerLend3CP
 * @notice LEND OWNER SAFE bundle, the one-way step on the Aave side. In a single atomic batch, for each
 *         of the three stocks: the wrapper reserve moves from the 1 wei placeholder to its live
 *         wrapper-rate feed, the mirror reserve moves to the 1 wei placeholder, and the mirror reserve is
 *         frozen. At no instant do both reserves count, so no borrower's health factor moves provided
 *         every safe's wrapper is already supplied. That check, and the health-factor simulation, are the
 *         go/no-go for signing this.
 *
 *         Frozen blocks supply and borrow on the mirror reserve but leaves withdraw and repay open, so
 *         users can still pull the worthless mirror dust out.
 *
 * Usage (after the listing bundle; the fork replays it if the wrappers are not yet listed live):
 *   forge script scripts/stock-migration/FlipStockReservesSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC -vvv
 */
contract FlipStockReservesSummerLend3CP is StockMigration3CPBase {
    string constant OUTPUT = "./output/FlipStockReservesSummerLend3CP-10.json";
    string constant LISTING_BUNDLE = "./output/ListStockWrappersSummerLend3CP-10.json";

    function run() public {
        _requireOptimismProd();
        MigrationFeeds memory feeds = _deployMigrationFeeds(true);
        MigratedStock[] memory stocks = StockMigration.all();
        uint256[] memory newIds = _newReserveIds(stocks);

        IAaveOracleLike oracle = IAaveOracleLike(LendRails.AAVE_ORACLE);
        uint256[] memory mirrorPrices = new uint256[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(oracle.getReserveSource(newIds[i]) == feeds.oneWei8, string.concat(s.symbol, ": wrapper reserve is not on the placeholder; already flipped?"));
            mirrorPrices[i] = oracle.getReservePrice(s.oldReserveId);
            require(mirrorPrices[i] > 1, string.concat(s.symbol, ": mirror reserve is already retired"));
            _logSupplied(s);
        }

        _writeBundle(stocks, newIds, feeds);
        console.log("Written: %s", OUTPUT);

        executeGnosisTransactionBundle(OUTPUT);
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            assertEq(oracle.getReserveSource(newIds[i]), feeds.wrapperUsd[i], "wrapper source");
            assertEq(oracle.getReserveSource(s.oldReserveId), feeds.oneWei8, "mirror source");
            assertEq(oracle.getReservePrice(s.oldReserveId), 1, "mirror price");
            assertApproxEqRel(oracle.getReservePrice(newIds[i]), mirrorPrices[i], 0.001e18, "wrapper price vs mirror before flip");
            assertTrue(spoke.getReserveConfig(s.oldReserveId).frozen, "mirror frozen");
            assertFalse(spoke.getReserveConfig(newIds[i]).frozen, "wrapper frozen");
            console.log(string.concat("  ", s.symbol, ": wrapper reserve ", vm.toString(newIds[i]), " live at ", vm.toString(oracle.getReservePrice(newIds[i])), "; mirror reserve ", vm.toString(s.oldReserveId), " at 1 wei, frozen"));
        }
        console.log("Simulation passed.");
    }

    function _writeBundle(MigratedStock[] memory stocks, uint256[] memory newIds, MigrationFeeds memory feeds) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.LEND_OWNER_SAFE));
        for (uint256 i = 0; i < stocks.length; ++i) {
            bool last = i == stocks.length - 1;
            txs = _append(txs, LendRails.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorMigrationLike.updateReservePriceSource, (LendRails.CASH_SPOKE, newIds[i], feeds.wrapperUsd[i])), false);
            txs = _append(txs, LendRails.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorMigrationLike.updateReservePriceSource, (LendRails.CASH_SPOKE, stocks[i].oldReserveId, feeds.oneWei8)), false);
            txs = _append(txs, LendRails.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorMigrationLike.freezeReserve, (LendRails.CASH_SPOKE, stocks[i].oldReserveId)), last);
        }
        vm.createDir("./output", true);
        vm.writeFile(OUTPUT, txs);
    }

    /// @dev The wrapper reserve ids; replays the listing bundle on the fork when they are not live yet.
    function _newReserveIds(MigratedStock[] memory stocks) internal returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](stocks.length);
        bool listed = true;
        for (uint256 i = 0; i < stocks.length; ++i) {
            ids[i] = _reserveIdOf(stocks[i].wrapper);
            listed = listed && ids[i] != type(uint256).max;
        }
        if (listed) return ids;

        require(vm.exists(LISTING_BUNDLE), "wrappers not listed; generate the listing bundle first");
        console.log("Wrappers not yet listed live; replaying the listing bundle on the fork");
        executeGnosisTransactionBundle(LISTING_BUNDLE);
        for (uint256 i = 0; i < stocks.length; ++i) {
            ids[i] = _reserveIdOf(stocks[i].wrapper);
            require(ids[i] != type(uint256).max, "listing bundle did not list the wrapper");
        }
        return ids;
    }

    /// @dev Informational: the hub's holdings show whether the lend sweep has moved the collateral over.
    ///      Left as a log, not a require, so the bundle can be generated for review ahead of the weekend.
    function _logSupplied(MigratedStock memory s) internal view {
        uint256 wrapperInHub = IERC20(s.wrapper).balanceOf(LendRails.CASH_HUB);
        uint256 mirrorInHub = IERC20(s.iToken).balanceOf(LendRails.CASH_HUB);
        console.log(string.concat("  ", s.symbol, " in hub: wrapper ", vm.toString(wrapperInHub), ", mirror ", vm.toString(mirrorInHub)));
        if (wrapperInHub == 0) console.log("    WARNING: no wrapper supplied yet. Do not sign until the lend sweep has run and verified.");
    }
}
