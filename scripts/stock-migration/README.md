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

Since the September 2026 re-gating, three timelocks sit between the Safes and some of these calls:

- **Lend timelock** `0xbaCa…e283`, 24h, on OP. Holds the Summer Lend configurator roles that list a reserve
  (200, 400) and set its price source (400). Its proposer and executor is the 3-of-6 Timelock Safe
  `0xd442…1166`. The listing and the price flip are each a `scheduleBatch` and an `executeBatch`.
- **Operating timelock** `0x9AEb…7849`, 8h, same address on both chains. Gates
  `TopUpFactory.removeTokenConfig` on Ethereum. The Operating Safe proposes and executes on it.
- **Upgrade timelock** `0x9106…4434`, 2 days, owns the Ethereum RoleRegistry. Gates the OFT adapter beacon
  upgrade that adds `sweepUnderlying` (OFT listing repo). The Operating Safe proposes and executes on it.

The Lend Owner Safe keeps pause (403) and freeze (402). The rest of the Cash side stays with the Operating Safe.

## Order

At least three days before the weekend (the stock feeds carry a 7 day staleness bound):

1. OFT listing repo: `DeployOFTAdapterSweepImpl` (EOA), then `UpgradeOFTAdapterBeaconForSweep`, Operating
   Safe: sign `-schedule-1.json`. Two days later, regenerate and sign `-execute-1.json`. Must execute before
   step 11; the sweep refuses to build until it has.
2. `DeployStockMigrationFeeds` as a registered EtherFiDeployer deployer. Records the five feeds in
   `summer-lend-feeds.json`.
3. `ListStockWrappersSummerLend3CP`, Timelock Safe: sign `-schedule-10.json`. Asset ids come from the live
   counters, so nothing else may be listed on the instance until step 4 executes. If something is, the
   Timelock Safe cancels and this is regenerated.
4. 24h later, regenerate and sign `ListStockWrappersSummerLend3CP-execute-10.json`, Timelock Safe. All three
   wrappers list in one transaction.
5. `ConfigureStockWrappersCashOP3CP`, Operating Safe, after step 4 executes (it reads the live reserve ids).
6. `FlipStockReservesSummerLend3CP`, Timelock Safe: sign only `-schedule-10.json`, at least 24h before the
   planned flip. Scheduling commits nothing: the flip only happens when step 14 executes it.
7. `PauseStockRailsEthereum3CP`, Operating Safe: sign only `-schedule-1.json` (the top-up config removal on
   the operating timelock), at least 8h before step 10.
8. Fund the Operating Safe on Ethereum with enough ETH for two bridge runs (about 0.002 ETH at today's CCIP
   fees). The bridge generator refuses to build when the Safe is short.

Friday night, before the snapshot:

9. `PauseStockReservesSummerLend3CP`, Lend Owner Safe. Paused blocks withdraw and liquidation of the mirror
   collateral; spending, borrowing and repaying still work. The snapshot block comes after this executes.

Weekend, Friday after the US close, Operating Safe on both chains:

10. `PauseStockRailsEthereum3CP-1.json` (adapters, StockUnwrapper, and the timelock execute that removes the
    wrapper top-up configs) and `PauseStockRailsOptimism3CP` (mirrors, StockWithdrawModule, both recovery
    modules). Let in-flight LayerZero messages settle first. TopUpDest and the PAXG adapter stay live.
11. `SweepStockAdapters3CP`, Ethereum: adapters to the Safe, wrappers redeemed to raw stock. Still reversible.
12. `BridgeStocksToOptimism3CP`, Ethereum, twice: `CANARY=true` for 0.01 of each, confirm the payout on OP
    after about 17 minutes, then the full balance. Point of no return.
13. Distribute and run the lend sweep, so every safe's wrapper is supplied.

After the health-factor simulation is green, back to back:

14. `FlipStockReservesSummerLend3CP-execute-10.json`, Timelock Safe. Every Aave price source moves in this one
    transaction. The Timelock Safe needs three signers available on the weekend.
15. `FreezeStockMirrorsSummerLend3CP-10.json`, Lend Owner Safe, right after step 14.
16. `FlipStockPricesCashOP3CP`, Operating Safe, right after step 14.
17. `UnpauseStockRailsOptimism3CP` (both recovery modules) and `UnpauseStockRailsEthereum3CP`
    (StockUnwrapper). The adapters, the mirrors and the StockWithdrawModule stay paused for good: the module
    only withdraws mirrors over the retired rail.

**Deadline.** Mirror-backed positions cannot be liquidated from step 9 until step 14. Step 14 must execute
before Monday's US open (9:30 ET). If it cannot, unpause the mirror reserves (Lend Owner Safe, the reverse of
step 9) so liquidations work again, cancel the queued flip, and retry the next weekend.

`test/migration/StockMigrationActionsFork.t.sol` runs steps 3 to 17 on the OP side against live state and
checks that a real safe can spend, borrow, repay and withdraw at every stage.

Every generator fork-simulates its own bundle and asserts the post-state before the JSON is trusted.
Generate against a local anvil fork if the public RPC rate-limits:

```
anvil --fork-url $OPTIMISM_RPC --port 8549 --compute-units-per-second 200 --retries 10
ENV=mainnet forge script scripts/stock-migration/<Script>.s.sol --rpc-url http://127.0.0.1:8549 -vv
```

The Ethereum bundles take `--rpc-url $MAINNET_RPC` (or a mainnet anvil fork) and check `block.chainid`,
so a bundle generated against the wrong chain fails before writing anything.
