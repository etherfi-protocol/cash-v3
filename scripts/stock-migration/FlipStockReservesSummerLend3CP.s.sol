// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { IAaveOracleLike, ISpokeLike, LendRails } from "../stock-listing/StockLendConfig.sol";
import { StockWrapperReserveIds } from "./ListStockWrappersSummerLend3CP.s.sol";
import { PauseStockReservesSummerLend3CP } from "./PauseStockReservesSummerLend3CP.s.sol";
import { ISpokeConfiguratorMigrationLike, MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title FlipStockReservesSummerLend3CP
 * @notice The one-way step on the Aave side, in three bundles:
 *
 *           1. TIMELOCK SAFE schedule: one scheduleBatch that, per stock, moves the wrapper reserve from the
 *              1 wei placeholder to its live wrapper-rate feed and the mirror reserve to the 1 wei placeholder.
 *           2. TIMELOCK SAFE execute: the matching executeBatch, at least 24h after the schedule. Every price
 *              source moves in this one transaction, so at no instant do both reserves count, and no
 *              borrower's health factor moves provided every safe's wrapper is already supplied. That check,
 *              and the health-factor simulation, are the go/no-go for signing it.
 *           3. LEND OWNER SAFE: freeze the three mirror reserves, right after the execute.
 *
 *         The price sources need the timelock's configurator role; the freeze stays with the Lend Owner Safe.
 *         The mirror reserves were paused on Friday and stay paused; frozen and 1 wei go on top so nothing
 *         about them ever counts or moves again.
 *
 * Usage (the fork rehearses the listing and the Friday pause when they are not live yet):
 *   forge script scripts/stock-migration/FlipStockReservesSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC -vvv
 */
contract FlipStockReservesSummerLend3CP is StockWrapperReserveIds {
    string constant SCHEDULE = "./output/FlipStockReservesSummerLend3CP-schedule-10.json";
    string constant EXECUTE = "./output/FlipStockReservesSummerLend3CP-execute-10.json";
    string constant FREEZE = "./output/FreezeStockMirrorsSummerLend3CP-10.json";

    function run() public {
        _requireOptimismProd();
        MigrationFeeds memory feeds = _deployMigrationFeeds(true);
        MigratedStock[] memory stocks = StockMigration.all();
        uint256[] memory newIds = _newReserveIds(stocks);
        _ensureMirrorsPaused(stocks);

        IAaveOracleLike oracle = IAaveOracleLike(LendRails.AAVE_ORACLE);
        uint256[] memory mirrorPrices = new uint256[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(oracle.getReserveSource(newIds[i]) == feeds.oneWei8, string.concat(s.symbol, ": wrapper reserve is not on the placeholder; already flipped?"));
            mirrorPrices[i] = oracle.getReservePrice(s.oldReserveId);
            require(mirrorPrices[i] > 1, string.concat(s.symbol, ": mirror reserve is already retired"));
            _logSupplied(s);
        }

        address[] memory targets = new address[](stocks.length * 2);
        bytes[] memory payloads = new bytes[](stocks.length * 2);
        for (uint256 i = 0; i < stocks.length; ++i) {
            targets[2 * i] = LendRails.SPOKE_CONFIGURATOR;
            payloads[2 * i] = abi.encodeCall(ISpokeConfiguratorMigrationLike.updateReservePriceSource, (LendRails.CASH_SPOKE, newIds[i], feeds.wrapperUsd[i]));
            targets[2 * i + 1] = LendRails.SPOKE_CONFIGURATOR;
            payloads[2 * i + 1] = abi.encodeCall(ISpokeConfiguratorMigrationLike.updateReservePriceSource, (LendRails.CASH_SPOKE, stocks[i].oldReserveId, feeds.oneWei8));
        }
        _writeTimelockBundles(SCHEDULE, EXECUTE, StockMigration.FLIP_SALT, targets, payloads);
        _writeFreezeBundle(stocks);

        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            assertEq(oracle.getReserveSource(newIds[i]), feeds.wrapperUsd[i], "wrapper source");
            assertEq(oracle.getReserveSource(s.oldReserveId), feeds.oneWei8, "mirror source");
            assertEq(oracle.getReservePrice(s.oldReserveId), 1, "mirror price");
            assertApproxEqRel(oracle.getReservePrice(newIds[i]), mirrorPrices[i], 0.001e18, "wrapper price vs mirror before flip");
            assertTrue(spoke.getReserveConfig(s.oldReserveId).frozen, "mirror frozen");
            assertTrue(spoke.getReserveConfig(s.oldReserveId).paused, "mirror must still be paused");
            assertFalse(spoke.getReserveConfig(newIds[i]).frozen, "wrapper frozen");
            console.log(string.concat("  ", s.symbol, ": wrapper reserve ", vm.toString(newIds[i]), " live at ", vm.toString(oracle.getReservePrice(newIds[i])), "; mirror reserve ", vm.toString(s.oldReserveId), " at 1 wei, frozen"));
        }
        console.log("Simulation passed.");
    }

    function _writeFreezeBundle(MigratedStock[] memory stocks) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.LEND_OWNER_SAFE));
        for (uint256 i = 0; i < stocks.length; ++i) {
            txs = _append(txs, LendRails.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorMigrationLike.freezeReserve, (LendRails.CASH_SPOKE, stocks[i].oldReserveId)), i == stocks.length - 1);
        }
        vm.writeFile(FREEZE, txs);
        console.log("Written: %s", FREEZE);
        executeGnosisTransactionBundle(FREEZE);
    }

    /// @dev The Friday pause bundle must have executed; rehearsed on the fork when it has not.
    function _ensureMirrorsPaused(MigratedStock[] memory stocks) internal {
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        bool paused = true;
        for (uint256 i = 0; i < stocks.length; ++i) {
            paused = paused && spoke.getReserveConfig(stocks[i].oldReserveId).paused;
        }
        if (paused) return;
        console.log("Mirror reserves not yet paused live; rehearsing the Friday pause on the fork");
        new PauseStockReservesSummerLend3CP().run();
    }

    /// @dev Informational: the hub's holdings show whether the lend sweep has moved the collateral over.
    ///      Left as a log, not a require, so the bundles can be generated for review ahead of the weekend.
    function _logSupplied(MigratedStock memory s) internal view {
        uint256 wrapperInHub = IERC20(s.wrapper).balanceOf(LendRails.CASH_HUB);
        uint256 mirrorInHub = IERC20(s.iToken).balanceOf(LendRails.CASH_HUB);
        console.log(string.concat("  ", s.symbol, " in hub: wrapper ", vm.toString(wrapperInHub), ", mirror ", vm.toString(mirrorInHub)));
        if (wrapperInHub == 0) console.log("    WARNING: no wrapper supplied yet. Do not sign until the lend sweep has run and verified.");
    }
}
