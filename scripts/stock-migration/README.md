# Moving SPYx, QQQx and TBLLx collateral onto Backed's OP wrappers

The three stock collaterals move from the Ethereum-locked mirror tokens (iwSPYx, iwQQQx, iwTBLLx) to
Backed's ERC-4626 wrappers on Optimism (wSPYx, wQQQx, wTBLLx), which live at the same addresses as on
Ethereum. Everything here is Optimism side. The Ethereum side (pausing and sweeping the OFT adapters,
unwrapping, bridging over Backed's CCIP bridge) lives in the OFT listing repo.

```
StockMigrationConfig.sol                 the three stocks, their live rails, feed identity strings
DeployStockMigrationFeeds.s.sol          five CREATE3 feeds: wrapper rate x <STOCK>/USD per stock,
                                         a 1 wei / 8 dec placeholder for Aave, a 1 unit / 6 dec one for Cash
StockMigration3CPBase.sol                shared plumbing for the bundles
ListStockWrappersSummerLend3CP.s.sol     Lend Owner Safe: list the wrappers at 1 wei, params copied from the mirrors
ConfigureStockWrappersCashOP3CP.s.sol    Operating Safe: Cash price, DebtManager collateral, gateway ids, withdraw assets
FlipStockReservesSummerLend3CP.s.sol     Lend Owner Safe, weekend: wrappers to live price, mirrors to 1 wei and frozen
RetireStockMirrorsCashOP3CP.s.sol        Operating Safe, weekend: mirrors to 1 unit on the Cash side
```

## Why 1 wei

Aave's oracle rejects a zero answer, when a source is set and on every account valuation, and nothing
else in the Spoke checks the resulting value. So the wrappers list at 1 wei: open for supply, worth
nothing for borrowing. The lend sweep moves every safe's wrapper in, verification runs, and one atomic
bundle then swaps the price sources. At no instant do a mirror and its wrapper both count.

PriceProviderV2 reports 6 decimals and would floor an 8-decimal 1 wei to zero and revert, hence the
separate 1 unit / 6 dec placeholder for the Cash side.

## Order

Before the weekend, any day (the stock feeds carry a 7 day staleness bound):

1. `DeployStockMigrationFeeds` as a registered EtherFiDeployer deployer. Records the five feeds in
   `summer-lend-feeds.json`.
2. `ListStockWrappersSummerLend3CP`, Lend Owner Safe. Regenerate right before signing: asset and
   reserve ids come from the live counters.
3. `ConfigureStockWrappersCashOP3CP`, Operating Safe. Needs the reserve ids from step 2, so it runs after
   step 2 executes (or replays step 2's JSON on the fork when generated in the same sitting).

Weekend, after the collateral has been bridged, wrapped, distributed and swept into Aave, and the
health-factor simulation is green:

4. `FlipStockReservesSummerLend3CP`, Lend Owner Safe. Prints a warning when the hub holds no wrapper yet.
5. `RetireStockMirrorsCashOP3CP`, Operating Safe, right after step 4.

Every generator fork-simulates its own bundle and asserts the post-state before the JSON is trusted.
Generate against a local anvil fork if the public RPC rate-limits:

```
anvil --fork-url $OPTIMISM_RPC --port 8549 --compute-units-per-second 200 --retries 10
ENV=mainnet forge script scripts/stock-migration/<Script>.s.sol --rpc-url http://127.0.0.1:8549 -vv
```
