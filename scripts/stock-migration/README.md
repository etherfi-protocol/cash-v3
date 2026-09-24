# Moving SPYx, QQQx and TBLLx collateral onto Backed's OP wrappers

The three stock collaterals move from the Ethereum-locked mirror tokens (iwSPYx, iwQQQx, iwTBLLx) to
Backed's ERC-4626 wrappers on Optimism (wSPYx, wQQQx, wTBLLx), which live at the same addresses as on
Ethereum. The OFT adapter upgrade that adds the owner sweep lives in the OFT listing repo; every bundle
that runs the move, on both chains, is here.

```
StockMigrationConfig.sol                 the three stocks, their live rails, feed identity strings
DeployStockMigrationFeeds.s.sol          five CREATE3 feeds: wrapper rate x <STOCK>/USD per stock,
                                         a 1 wei / 8 dec placeholder for Aave, a 1 unit / 6 dec one for Cash
StockMigration3CPBase.sol                shared plumbing for the bundles, including the lend timelock schedule/execute pair
ListStockWrappersSummerLend3CP.s.sol     Timelock Safe, schedule then execute: list the wrappers at 1 wei, params copied from the mirrors
ConfigureStockWrappersCashOP3CP.s.sol    Operating Safe: wrappers at the 1 unit placeholder, DebtManager collateral, gateway ids, withdraw assets
PauseStockReservesSummerLend3CP.s.sol    Lend Owner Safe, Friday: pause the mirror reserves so the snapshot cannot drift
FlipStockReservesSummerLend3CP.s.sol     Timelock Safe, schedule then execute: wrappers to live price, mirrors to 1 wei;
                                         then Lend Owner Safe: freeze the mirrors
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

## Who signs what

Since 2026-09-19 the Summer Lend configurator roles that list a reserve (200, 400) and set its price source
(400) sit with the lend timelock `0xbaCa…e283`, which has a 24h delay. Its proposer and executor is the
3-of-6 Timelock Safe `0xd442…1166`. So the listing and the price flip are each two Timelock Safe bundles:
a `scheduleBatch`, then an `executeBatch` at least 24h later. The Lend Owner Safe keeps pause (403) and
freeze (402). The Cash side stays with the Operating Safe.

## Order

At least two days before the weekend (the stock feeds carry a 7 day staleness bound):

1. `DeployStockMigrationFeeds` as a registered EtherFiDeployer deployer. Records the five feeds in
   `summer-lend-feeds.json`.
2. `ListStockWrappersSummerLend3CP`, Timelock Safe: sign `-schedule-10.json`. Asset ids come from the live
   counters, so nothing else may be listed on the instance until step 3 executes. If something is, the
   Timelock Safe cancels and this is regenerated.
3. 24h later, regenerate and sign `ListStockWrappersSummerLend3CP-execute-10.json`, Timelock Safe. All three
   wrappers list in one transaction.
4. `ConfigureStockWrappersCashOP3CP`, Operating Safe, after step 3 executes (it reads the live reserve ids).
5. `FlipStockReservesSummerLend3CP`, Timelock Safe: sign only `-schedule-10.json`, at least 24h before the
   planned flip. Scheduling commits nothing: the flip only happens when step 11 executes it.

Friday night, before the snapshot:

6. `PauseStockReservesSummerLend3CP`, Lend Owner Safe. Paused blocks withdraw and liquidation of the mirror
   collateral; spending, borrowing and repaying still work. The snapshot block comes after this executes.

Weekend, Friday after the US close, Operating Safe on both chains:

7. `PauseStockRailsEthereum3CP` (adapters, wrapper top-up configs, StockUnwrapper) and
   `PauseStockRailsOptimism3CP` (mirrors, StockWithdrawModule, both recovery modules). Let in-flight
   LayerZero messages settle first. TopUpDest and the PAXG adapter stay live.
8. `SweepStockAdapters3CP`, Ethereum: adapters to the Safe, wrappers redeemed to raw stock. Still reversible.
9. `BridgeStocksToOptimism3CP`, Ethereum, twice: `CANARY=true` for 0.01 of each, confirm the payout on OP
   after about 17 minutes, then the full balance. Point of no return. The Safe needs ETH for the CCIP fees.
10. Distribute and run the lend sweep, so every safe's wrapper is supplied.

After the health-factor simulation is green, back to back:

11. `FlipStockReservesSummerLend3CP-execute-10.json`, Timelock Safe. Every Aave price source moves in this one
    transaction. The Timelock Safe needs three signers available on the weekend.
12. `FreezeStockMirrorsSummerLend3CP-10.json`, Lend Owner Safe, right after step 11.
13. `FlipStockPricesCashOP3CP`, Operating Safe, right after step 11.
14. `UnpauseStockRailsOptimism3CP` and `UnpauseStockRailsEthereum3CP`: modules and StockUnwrapper come
    back. Adapters and mirrors stay paused for good.

`test/migration/StockMigrationActionsFork.t.sol` runs steps 2 to 14 on the OP side against live state and
checks that a real safe can spend, borrow, repay and withdraw at every stage.

Every generator fork-simulates its own bundle and asserts the post-state before the JSON is trusted.
Generate against a local anvil fork if the public RPC rate-limits:

```
anvil --fork-url $OPTIMISM_RPC --port 8549 --compute-units-per-second 200 --retries 10
ENV=mainnet forge script scripts/stock-migration/<Script>.s.sol --rpc-url http://127.0.0.1:8549 -vv
```

The Ethereum bundles take `--rpc-url $MAINNET_RPC` (or a mainnet anvil fork) and check `block.chainid`,
so a bundle generated against the wrong chain fails before writing anything.
