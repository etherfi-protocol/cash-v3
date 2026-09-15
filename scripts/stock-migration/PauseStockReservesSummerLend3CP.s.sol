// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { ISpokeLike, LendRails } from "../stock-listing/StockLendConfig.sol";
import { StockMigration3CPBase } from "./StockMigration3CPBase.sol";
import { ISpokeConfiguratorMigrationLike, MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title PauseStockReservesSummerLend3CP
 * @notice LEND OWNER SAFE bundle, Friday night, right before the snapshot: pause the three mirror reserves.
 *         A paused reserve blocks supply, withdraw and liquidation of that collateral, so between the
 *         snapshot and the flip nobody's mirror position can move. Repaying USDC or WETH debt is unaffected,
 *         and every other reserve keeps working. The mirrors stay paused for good; the flip adds 1 wei and
 *         frozen on top.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/stock-migration/PauseStockReservesSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC -vv
 */
contract PauseStockReservesSummerLend3CP is StockMigration3CPBase {
    string constant OUTPUT = "./output/PauseStockReservesSummerLend3CP-10.json";

    function run() public {
        _requireOptimismProd();
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        MigratedStock[] memory stocks = StockMigration.all();

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.LEND_OWNER_SAFE));
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(spoke.getReserve(s.oldReserveId).underlying == s.iToken, string.concat(s.symbol, ": reserve id does not hold the mirror"));
            require(!spoke.getReserveConfig(s.oldReserveId).paused, string.concat(s.symbol, ": mirror reserve already paused"));
            txs = _append(txs, LendRails.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorMigrationLike.updatePaused, (LendRails.CASH_SPOKE, s.oldReserveId, true)), i == stocks.length - 1);
        }
        vm.createDir("./output", true);
        vm.writeFile(OUTPUT, txs);
        console.log("Written: %s", OUTPUT);

        executeGnosisTransactionBundle(OUTPUT);
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertTrue(spoke.getReserveConfig(stocks[i].oldReserveId).paused, "mirror reserve not paused");
        }
        console.log("Simulation passed: mirror reserves 19, 21, 22 paused.");
    }
}
