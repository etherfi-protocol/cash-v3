# xStocks on OP: SPYx, QQQx and TBLLx on Backed's native Optimism wrappers

Scripts for moving the three stocks' collateral from the LayerZero stand-ins (iwSPYx, iwQQQx, iwTBLLx) to
Backed's ERC-4626 wrappers on Optimism, and for routing mainnet top-ups of the raw stocks over Backed's CCIP
bridge. The contracts are in cash-v3 PR #331.

```
XStocksOPProdConfig.sol        fixed addresses, selectors, manifest keys, the three stocks
DeployXStocksOP.s.sol          OP, EOA: wrapper feeds, three modules (impl + proxy), TopUpDest impl
DeployBackedCCIPAdapterEth.s.sol  Ethereum, EOA: the TopUpFactory adapter for Backed's bridge
XStocksOPLaunch3CP.s.sol       OP, Admin / Upgrade / Operating Safe: six bundles plus an optional seed bundle
XStocksTopUpEth3CP.s.sol       Ethereum, Operating Safe: schedule and execute the top-up token config
```

Every generator fork-simulates the bundles it writes and asserts the post-state before the JSON is trusted.
Every gate is read from the live RoleRegistry first; a role that moved to a timelock since the scripts were
written fails the precondition instead of producing a wrong bundle.

## Run order

1. **Deploy on Optimism** (EOA, registered EtherFiDeployer deployer). Immutable feeds and unconfigured
   modules, safe to run before anything is proposed. Records addresses in `deployments/mainnet/10`.

   ```sh
   source .env && forge script scripts/xstocks-op/DeployXStocksOP.s.sol --rpc-url $OPTIMISM_RPC --account dev-admin --broadcast --verify -vvv
   ```

2. **Deploy on Ethereum** (EOA). Records the adapter in `deployments/mainnet/1`.

   ```sh
   source .env && forge script scripts/xstocks-op/DeployBackedCCIPAdapterEth.s.sol --rpc-url $MAINNET_RPC --account dev-admin --broadcast --verify -vvv
   ```

3. **Summer Lend listing** (aave-v4 repo, lend timelock, 24h). List wSPYx, wQQQx and wTBLLx on the Cash
   spoke at the wrapper feeds from step 1, with the stand-in reserves' parameters. The OP generator below
   rehearses this listing on its fork when it has not executed yet, and reads the reserve ids once it has.

4. **Generate the OP bundles** (no broadcast). Regenerate right before signing.

   ```sh
   forge script scripts/xstocks-op/XStocksOPLaunch3CP.s.sol --rpc-url $OPTIMISM_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
   ```

   Each timelock is driven by the Safe that operates it: the Admin Safe on the 8h admin timelock, the Upgrade
   Safe on the 2d upgrade timelock. The ADMIN_ROLE setters come straight from the Operating Safe.

   | Bundle | Safe | When | What |
   |---|---|---|---|
   | `admin-safe-step1-schedule` | Admin | session day | schedule the modules batch (8h: swap and wrap pairs, bridge wrappers, default modules, bridge module on the can-request list, migration module as driver) and the TopUpDest wrappers batch (8h) |
   | `upgrade-safe-step1-schedule` | Upgrade | session day | schedule the TopUpDest upgrade (2d) |
   | `admin-safe-step2-execute-modules` | Admin | 8h later | execute the modules batch |
   | `controller-safe-step2-config` | Operating | after the lend listing executed | wrapper prices on PriceProviderV2, DebtManager collateral, LendGateway reserve ids, withdraw assets |
   | `upgrade-safe-step3-execute-upgrade` | Upgrade | 2d later | execute the upgrade |
   | `admin-safe-step3-execute-wrappers` | Admin | after the upgrade | execute the wrappers batch |
   | `seed` | Operating | with step 2 or later | wrapper from the Safe into the migration module and the TopUpDest buffer; written only when `XSTOCKS_SEED_<SYMBOL>` or `XSTOCKS_BUFFER_<SYMBOL>` is set, amounts in wrapper wei |

5. **Generate the Ethereum bundles** (no broadcast).

   ```sh
   forge script scripts/xstocks-op/XStocksTopUpEth3CP.s.sol --rpc-url $MAINNET_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
   ```

   `step1-schedule` on the session day, `step2-execute` 8h later. Routes raw SPYx, QQQx and TBLLx top-ups to
   TopUpDest on Optimism over the adapter from step 2. The LayerZero routes are keyed on the mainnet wrappers,
   not the raw stocks, so they are untouched and keep working until the mirrors are retired.

## Pricing

The wrappers get a PriceProviderV2 entry that reads the vault's own redemption rate (`convertToAssets`) on the
raw stock's existing USD entry. The Aave feed composes the same two legs, so the cash side and the lend side
price a wrapper identically, and neither depends on the relay keeper that the stand-ins use. The simulation
asserts both prices land within 10 bps of the stand-in's.

## Out of scope here

The mirror float in TopUpDest and the stand-in reserves are retired after the swaps, in a separate bundle.
