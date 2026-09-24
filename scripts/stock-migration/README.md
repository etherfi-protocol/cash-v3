# Moving SPYx, QQQx and TBLLx collateral onto Backed's OP wrappers

The three stock collaterals move from the Ethereum-locked mirror tokens (iwSPYx, iwQQQx, iwTBLLx) to
Backed's ERC-4626 wrappers on Optimism (wSPYx, wQQQx, wTBLLx), which live at the same addresses as on
Ethereum. The OFT adapter upgrade that adds the owner sweep lives in the OFT listing repo; every bundle
that runs the move, on both chains, is here.

```
StockMigrationConfig.sol                 the three stocks, their live rails, feed identity strings
DeployStockMigrationFeeds.s.sol          five CREATE3 feeds: wrapper rate x <STOCK>/USD per stock,
                                         a 1 wei / 8 dec placeholder for Aave, a 1 unit / 6 dec one for Cash
StockMigration3CPBase.sol                shared plumbing for the bundles
ListStockWrappersSummerLend3CP.s.sol     Lend Owner Safe: list the wrappers at 1 wei, params copied from the mirrors
ConfigureStockWrappersCashOP3CP.s.sol    Operating Safe: wrappers at the 1 unit placeholder, DebtManager collateral, gateway ids, withdraw assets
PauseStockReservesSummerLend3CP.s.sol    Lend Owner Safe, Friday: pause the mirror reserves so the snapshot cannot drift
FlipStockReservesSummerLend3CP.s.sol     Lend Owner Safe, weekend: wrappers to live price, mirrors to 1 wei and frozen
FlipStockPricesCashOP3CP.s.sol           Operating Safe, weekend: wrappers to live price, mirrors to 1 unit, one tx
PauseStockRails3CP.s.sol                 Operating Safe, both chains: pause the adapters, mirrors, top-up configs
                                         and modules; unpause the modules and StockUnwrapper afterwards
SweepStockAdapters3CP.s.sol              Operating Safe, Ethereum: sweep the paused adapters, redeem to raw stock
BridgeStocksToOptimism3CP.s.sol          Operating Safe, Ethereum: send the raw stock to the OP Safe over Backed's bridge
```

## Why 1 wei

Aave's oracle rejects a zero answer, when a source is set and on every account valuation, and nothing
else in the Spoke checks the resulting value. So the wrappers list at 1 wei: open for supply, worth
nothing for borrowing. The lend sweep moves every safe's wrapper in, verification runs, and one atomic
bundle then swaps the price sources. At no instant do a mirror and its wrapper both count.

PriceProviderV2 reports 6 decimals and would floor an 8-decimal 1 wei to a price of 0. Collateral value
would read as 0 and any USD-to-token conversion would divide by zero and revert, hence the separate
1 unit / 6 dec placeholder for the Cash side. The Cash side follows the same shape: wrappers list at the
placeholder, and one transaction later moves wrappers to the live rate and mirrors to the placeholder, so
a DebtManager safe never counts both.

## Order

Before the weekend, any day (the stock feeds carry a 7 day staleness bound):

1. `DeployStockMigrationFeeds` as a registered EtherFiDeployer deployer. Records the five feeds in
   `summer-lend-feeds.json`.
2. `ListStockWrappersSummerLend3CP`, Lend Owner Safe. Regenerate right before signing: asset and
   reserve ids come from the live counters.
3. `ConfigureStockWrappersCashOP3CP`, Operating Safe. Needs the reserve ids from step 2, so it runs after
   step 2 executes (or replays step 2's JSON on the fork when generated in the same sitting).

Friday night, before the snapshot:

3b. `PauseStockReservesSummerLend3CP`, Lend Owner Safe. Paused blocks withdraw and liquidation of the mirror
   collateral; repaying USDC or WETH debt still works. The snapshot block comes after this executes.

Weekend, Friday after the US close, Operating Safe on both chains:

4. `PauseStockRailsEthereum3CP` (adapters, wrapper top-up configs, StockUnwrapper) and
   `PauseStockRailsOptimism3CP` (mirrors, StockWithdrawModule, both recovery modules). Let in-flight
   LayerZero messages settle first. TopUpDest and the PAXG adapter stay live.
5. `SweepStockAdapters3CP`, Ethereum: adapters to the Safe, wrappers redeemed to raw stock. Still reversible.
6. `BridgeStocksToOptimism3CP`, Ethereum, twice: `CANARY=true` for 0.01 of each, confirm the payout on OP
   after about 17 minutes, then the full balance. Point of no return. The Safe needs ETH for the CCIP fees.

After the collateral has been wrapped, distributed and swept into Aave, and the health-factor simulation
is green:

7. `FlipStockReservesSummerLend3CP`, Lend Owner Safe. Prints a warning when the hub holds no wrapper yet.
8. `FlipStockPricesCashOP3CP`, Operating Safe, right after step 7.
9. `UnpauseStockRailsOptimism3CP` and `UnpauseStockRailsEthereum3CP`: modules and StockUnwrapper come
   back. Adapters and mirrors stay paused for good.

Every generator fork-simulates its own bundle and asserts the post-state before the JSON is trusted.
Generate against a local anvil fork if the public RPC rate-limits:

```
anvil --fork-url $OPTIMISM_RPC --port 8549 --compute-units-per-second 200 --retries 10
ENV=mainnet forge script scripts/stock-migration/<Script>.s.sol --rpc-url http://127.0.0.1:8549 -vv
```

The Ethereum bundles take `--rpc-url $MAINNET_RPC` (or a mainnet anvil fork) and check `block.chainid`,
so a bundle generated against the wrong chain fails before writing anything.
