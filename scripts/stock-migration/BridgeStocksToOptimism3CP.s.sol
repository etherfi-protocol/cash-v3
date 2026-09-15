// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { StockRailsBundleBase } from "./PauseStockRails3CP.s.sol";
import { IBackedCCIPBridge, MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title BridgeStocksToOptimism3CP
 * @notice OPERATING SAFE bundle on Ethereum, weekend step 5, the point of no return: send the raw stock to
 *         the Operating Safe on Optimism over Backed's CCIP bridge. Per stock, `approve` then `send` with the
 *         CCIP fee as the transaction value. Delivery takes about 17 minutes (Ethereum finality).
 *
 *         Run twice. `CANARY=true` sends 0.01 of each so the payout can be confirmed on OP first; the default
 *         sends the Safe's whole balance of each. Amounts and fees are read live at generation time, so
 *         regenerate right before signing.
 *
 *         The bridge forwards exactly the quoted fee to CCIP and keeps any excess, so the value is the live
 *         quote plus 20 percent, not more. The Safe must hold enough ETH for the three values plus gas.
 *
 * Usage:
 *   CANARY=true ENV=mainnet forge script scripts/stock-migration/BridgeStocksToOptimism3CP.s.sol --rpc-url $MAINNET_RPC -vv
 *   ENV=mainnet forge script scripts/stock-migration/BridgeStocksToOptimism3CP.s.sol --rpc-url $MAINNET_RPC -vv
 */
contract BridgeStocksToOptimism3CP is StockRailsBundleBase {
    uint256 constant CANARY_AMOUNT = 0.01e18;
    uint256 constant FEE_BUFFER_BPS = 12_000;
    /// @dev Backed's custody wallet, where `send` pulls the tokens; same address on both chains.
    address constant BACKED_CUSTODY = 0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD;

    function run() public {
        _requireChain(1);
        bool canary = vm.envOr("CANARY", false);
        string memory output = canary ? "./output/BridgeStocksToOptimismCanary3CP-1.json" : "./output/BridgeStocksToOptimism3CP-1.json";
        IBackedCCIPBridge bridge = IBackedCCIPBridge(StockMigration.BACKED_BRIDGE);
        bytes32 receiver = bytes32(uint256(uint160(StockMigration.OPERATING_SAFE)));
        MigratedStock[] memory stocks = StockMigration.all();

        require(!bridge.paused(), "Backed bridge is paused");
        require(bridge.allowlistedDestinationChains(StockMigration.OP_CHAIN_SELECTOR) != bytes32(0), "Optimism lane not registered on the bridge");

        uint256[] memory amounts = new uint256[](stocks.length);
        uint256[] memory values = new uint256[](stocks.length);
        uint256[] memory custodyBefore = new uint256[](stocks.length);
        uint256 totalValue;
        string memory txs = _header();
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(bridge.tokenIds(s.stock) != 0, string.concat(s.symbol, ": not registered on the bridge"));
            uint256 balance = IERC20(s.stock).balanceOf(StockMigration.OPERATING_SAFE);
            amounts[i] = canary ? CANARY_AMOUNT : balance;
            require(amounts[i] > 0 && balance >= amounts[i], string.concat(s.symbol, ": Safe holds less raw stock than the send amount"));
            values[i] = bridge.getDeliveryFeeCost(StockMigration.OP_CHAIN_SELECTOR, receiver, s.stock, amounts[i], "") * FEE_BUFFER_BPS / 10_000;
            totalValue += values[i];
            custodyBefore[i] = IERC20(s.stock).balanceOf(BACKED_CUSTODY);
            console.log(string.concat("  ", s.symbol, ": send ", vm.toString(amounts[i]), " raw, fee value ", vm.toString(values[i]), " wei"));

            txs = _append(txs, s.stock, abi.encodeCall(IERC20.approve, (address(bridge), amounts[i])), false);
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(bridge)), iToHex(abi.encodeCall(IBackedCCIPBridge.send, (StockMigration.OP_CHAIN_SELECTOR, receiver, s.stock, amounts[i], ""))), vm.toString(values[i]), i == stocks.length - 1));
        }
        uint256 safeEth = StockMigration.OPERATING_SAFE.balance;
        console.log(string.concat("  Safe ETH ", vm.toString(safeEth), " wei; bundle needs ", vm.toString(totalValue), " wei plus gas"));
        require(safeEth >= totalValue, "Safe holds less ETH than the bridge fees; fund it first");
        _write(output, txs);

        executeGnosisTransactionBundle(output);
        // Backed's send converts the amount to shares and back, so custody can land 1 wei short.
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertApproxEqAbs(IERC20(stocks[i].stock).balanceOf(BACKED_CUSTODY) - custodyBefore[i], amounts[i], 2, "custody did not receive the send amount");
        }
        console.log(canary ? "Simulation passed (canary). Confirm the payout on OP before the full send." : "Simulation passed (full send).");
    }
}
