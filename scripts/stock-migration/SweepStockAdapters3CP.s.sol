// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { StockRailsBundleBase } from "./PauseStockRails3CP.s.sol";
import { IPausableBridge, MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title SweepStockAdapters3CP
 * @notice OPERATING SAFE bundle on Ethereum, weekend step 4: empty the three OFT adapters into the Safe and
 *         unwrap the collateral to raw SPYx, QQQx and TBLLx, ready for the bridge. Six calls: per stock,
 *         `sweepUnderlying(safe)` on the adapter (owner only, paused only) then `redeem` on Backed's wrapper
 *         for exactly the swept shares.
 *
 *         Reversible: while the raw stock sits in the Safe, depositing it back into the wrapper and the
 *         adapter, then unpausing, restores today's state. The bridge send that follows is not.
 *
 *         Requires the adapter beacon upgrade (OFT listing repo) to have executed and the Ethereum pause
 *         bundle to have run. If the adapters are still unpaused on the fork, the pause bundle JSON is
 *         replayed first so both can be generated in one sitting.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/stock-migration/SweepStockAdapters3CP.s.sol --rpc-url $MAINNET_RPC -vv
 */
contract SweepStockAdapters3CP is StockRailsBundleBase {
    string constant OUTPUT = "./output/SweepStockAdapters3CP-1.json";
    string constant PAUSE_BUNDLE = "./output/PauseStockRailsEthereum3CP-1.json";

    function run() public {
        _requireChain(1);
        MigratedStock[] memory stocks = StockMigration.all();
        _requireSweepLive(stocks);
        _ensurePaused(stocks);

        uint256[] memory shares = new uint256[](stocks.length);
        uint256[] memory rawBefore = new uint256[](stocks.length);
        string memory txs = _header();
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            shares[i] = IERC20(s.wrapper).balanceOf(s.adapter);
            rawBefore[i] = IERC20(s.stock).balanceOf(StockMigration.OPERATING_SAFE);
            require(shares[i] > 0, string.concat(s.symbol, ": adapter holds nothing"));
            console.log(string.concat("  ", s.symbol, ": sweeping ", vm.toString(shares[i]), " wrapper shares, worth ", vm.toString(IERC4626(s.wrapper).convertToAssets(shares[i])), " raw"));
            txs = _append(txs, s.adapter, abi.encodeCall(IPausableBridge.sweepUnderlying, (StockMigration.OPERATING_SAFE)), false);
            txs = _append(txs, s.wrapper, abi.encodeCall(IERC4626.redeem, (shares[i], StockMigration.OPERATING_SAFE, StockMigration.OPERATING_SAFE)), i == stocks.length - 1);
        }
        _write(OUTPUT, txs);

        executeGnosisTransactionBundle(OUTPUT);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            assertEq(IERC20(s.wrapper).balanceOf(s.adapter), 0, "adapter not empty");
            assertEq(IERC20(s.wrapper).balanceOf(StockMigration.OPERATING_SAFE), 0, "wrapper left in the Safe");
            uint256 gained = IERC20(s.stock).balanceOf(StockMigration.OPERATING_SAFE) - rawBefore[i];
            assertApproxEqAbs(gained, IERC4626(s.wrapper).convertToAssets(shares[i]), 10, "raw received differs from redeem value");
            console.log(string.concat("  ", s.symbol, ": Safe now holds ", vm.toString(IERC20(s.stock).balanceOf(StockMigration.OPERATING_SAFE)), " raw"));
        }
        console.log("Simulation passed.");
    }

    /// @dev Probes for the upgraded implementation on an unpaused adapter: the owner's sweep must revert with
    ///      ExpectedPause. An empty revert means the selector does not exist, so the beacon upgrade has not run.
    function _requireSweepLive(MigratedStock[] memory stocks) internal {
        for (uint256 i = 0; i < stocks.length; ++i) {
            if (IPausableBridge(stocks[i].adapter).paused()) continue;
            vm.prank(StockMigration.OPERATING_SAFE);
            (bool ok, bytes memory err) = stocks[i].adapter.call(abi.encodeCall(IPausableBridge.sweepUnderlying, (StockMigration.OPERATING_SAFE)));
            require(!ok, "sweep succeeded on an unpaused adapter");
            require(err.length >= 4, string.concat(stocks[i].symbol, ": adapter has no sweep; execute the beacon upgrade bundle first"));
        }
    }

    function _ensurePaused(MigratedStock[] memory stocks) internal {
        bool allPaused = true;
        for (uint256 i = 0; i < stocks.length; ++i) {
            allPaused = allPaused && IPausableBridge(stocks[i].adapter).paused();
        }
        if (allPaused) return;
        require(vm.exists(PAUSE_BUNDLE), "adapters not paused; generate the Ethereum pause bundle first");
        console.log("Adapters not yet paused live; replaying the pause bundle on the fork");
        executeGnosisTransactionBundle(PAUSE_BUNDLE);
    }
}
