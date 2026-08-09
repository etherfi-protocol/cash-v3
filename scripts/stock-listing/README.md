# xStock Summer Lend / DebtManager collateral rollout

Reusable structure for listing a 4626-wrapped xStock's iToken as collateral on the prod Summer
Lend instance and the DebtManager, following the iToken's cash-mainnet-asset-listing bundles
(which ship the OFT rails and price the wrapper over the PriceRelay (ETH) -> OracleSink (OP)
path). QQQx / iwQQQx is the first asset listed this way.

**Scope is 4626-wrapped stocks only** — a base stock token that is a PriceProviderV2 price KEY
(never bridged) plus a wrapper that bridges and relays its rate. PAXG does not fit this shape: it
relays a full USD price with no base composition, so it stays its own bundle rather than forcing
dead fields and a branchy generator onto this abstraction.

```
StockLendConfig.sol              library LendRails + struct StockLendAsset + the local aave-v4
                                  interface mirrors
StockLendAssets.sol               library StockLendAssets { function wqqqx() ... }
DeployStockProdFeeds.s.sol        abstract StockFeedDeployer (shared feed-deploy/rehearsal core)
                                   + abstract DeployStockProdFeedsBase + contract DeployQqqxProdFeeds
ListStockSummerLend3CP.s.sol      abstract ListStockSummerLend3CPBase + contract ListQqqxSummerLend3CP
ConfigureStockCashOP3CP.s.sol     abstract ConfigureStockCashOP3CPBase + contract ConfigureQqqxCashOP3CP
```

Adding a second xStock is: one `StockLendAssets.<symbol>()` entry (the struct literal, ~20 lines)
plus three one-line concrete contracts (`_asset()` + a literal output path each). Everything else
— feed deployment/CREATE3, the Hub/Spoke/DebtManager calldata shape, the fork rehearsal of the
not-yet-live OFT/relay rails, and every pre-flight and post-state assertion — is shared.

There is no PAXG-style oracle repoint or retirement bundle in this shape — the wrapper's relay leg
is permanent. An iToken's pricing on OP (both the cash `PriceProviderV2` and the Summer Lend feed)
is the relayed wrapper -> stock rate composed on the Chainlink `<STOCK>/USD` feed, indefinitely.

## The rollout, in execution order

1. **`Deploy*ProdFeeds`** (EOA, registered EtherFiDeployer deployer) — deploys two immutable Aave
   v4 price feeds on Optimism via CREATE3 and merges their addresses into
   `deployments/mainnet/10/summer-lend-feeds.json`.
2. **`List*SummerLend3CP`** (Lend Owner Safe, OP) — hub + spoke reserve listing against the feed
   from step 1.
3. **`Configure*CashOP3CP`** (Operating Safe, OP) — DebtManager collateral support + LendGateway
   reserve id registration for the reserve from step 2.

Every generator fork-simulates its own bundle (step 3 replays step 2's JSON first when the reserve
is not yet live) and asserts the post-state before the JSON is trusted.

**Execution ordering is load-bearing:**

1. The feeds (step 1) must exist and price before the Lend Owner Safe bundle lists a reserve
   against them.
2. The Lend Owner Safe bundle (step 2) must execute before the Operating Safe OP bundle (step 3):
   `LendGateway.setReserveId` registers the reserve id step 2 assigns.
3. Simulate and execute steps 2-3 while the base `<STOCK>/USD` feed is fresh (within its staleness
   window of the last market close) — both the reserve listing and `supportCollateralToken` read
   the live price.
4. Real execution of every step above additionally requires the corresponding
   cash-mainnet-asset-listing bundle(s) to have executed and the relay keeper to have poked at
   least once — see the "prerequisite" note below.

## The ADDRESS-AFFECTING feed identity strings

`feedSaltPrefix`, `stockFeedName`, `wrapperFeedName`, `stockFeedDesc`, and `wrapperFeedDesc` on
`StockLendAsset` are baked into each feed's CREATE3 salt and/or constructor initcode. Changing any
one of them for an already-listed asset moves the deployed feed address and therefore the
`addReserve` price source — they are per-asset struct fields, never shared, never defaulted.
`expectedStockFeed`/`expectedWrapperFeed` are a refactor-time regression guard: the exact addresses
an asset's feeds already deployed to, asserted in `StockFeedDeployer._deployFeeds` so a typo in any
of the five strings above fails loudly instead of silently deploying a different feed. A brand-new
asset has no prior address to check, so it sets both to `address(0)` to skip the check.

## Why an iToken is deliberately uncapped

Every other rate-composed reserve on the live Summer Lend instance sits behind a
`CLRatePriceCapAdapter`. A 4626-wrapped xStock does not, and should not: on a constituent split or
a share split, the wrapper -> stock rate jumps by the split factor while `<STOCK>/USD` drops by the
same factor. The composed price stays continuous, but an immutable growth cap on the rate leg
would clamp that jump and under-price every position by the split ratio, with no way to
re-snapshot an immutable cap. A legitimate unbounded jump makes a growth cap the wrong tool.
Direct feeds like iPAXG's are not applicable here: a 4626-wrapped xStock has no independent USD
market price to feed from, only the relayed rate.

## Fork rehearsal

For a brand-new asset, the cash-mainnet-asset-listing rails it depends on (the iToken ShadowOFT and
a relayed wrapper price on the OracleSink) will not exist anywhere yet — not even on a clean
mainnet fork — until that repo's bundles execute. Every generator here still **generates and
fork-rehearses** regardless, via `_rehearseStockRails()` (deploys the real iToken ShadowOFT through
the real factory/salt, and seeds a relayed sink price by writing directly into the sink's storage)
and, in `Configure*CashOP3CP` specifically, a fork-only prank of the Operating Safe through the
real `PriceProviderV2.setTokenConfig` reproducing the other repo's exact base-entry config. Both
are fork-only, logged loudly (`[REHEARSAL]`), and never emitted as calldata in either bundle — they
exist purely so this repo's scripts can be authored and rehearsed without waiting on the other
repo's PR to merge and execute.

## QQQx / iwQQQx worked example

| | DebtManager (LTV / LT / bonus) | Summer Lend (CF / max bonus / liq fee) | Add cap |
|---|---|---|---|
| iwQQQx | 73% / 78% / 7.5% | 78% / 10% / 10% | 2,000 |

Collateral-only (borrowable no, draw cap 0), collateral risk 0 bps, flat 0% IR curve
(`optimalUsageRatio` 99%, all rate-growth params 0), 0% liquidity fee — the same collateral-only
house style used for iwSPYx, and shared across every asset via `LendRails`.

QQQ/USD and the relayed wQQQx -> QQQx rate are both **3 days** on the Aave v4 feed leg
(`DeployQqqxProdFeeds`). The relay keeper must poke **at least every 3 days** — this is the
binding cadence, tighter than the OracleSink's own 7-day window. QQQ/USD is a 24/5 feed, so a
US-market holiday weekend longer than 72h reads stale (fail-closed, on both the cash and lend
sides) until reopen.

### Prerequisite, stated loudly: the OracleSink has never held a wQQQx price

As of 2026-08-09 the prod OracleSink holds **no** wQQQx entry, and the iwQQQx ShadowOFT on
Optimism does not exist — the cash-mainnet-asset-listing Ethereum bundle has not executed, and its
Optimism bundle (which deploys the ShadowOFT and writes the cash-side `PriceProviderV2` entry) has
not either. Until the Ethereum bundle executes and the relay keeper pokes:

- `_requireLivePrice` in `DeployQqqxProdFeeds` reverts on the iwQQQx feed,
- `DebtManager.supportCollateralToken` reverts (it reads the iwQQQx price through
  `PriceProviderV2`, whose entry the other repo's Optimism bundle writes).

### Run order

```sh
# 1. EOA (registered EtherFiDeployer deployer): immutable feeds on OP + manifest update
source .env && ENV=mainnet forge script \
  scripts/stock-listing/DeployStockProdFeeds.s.sol:DeployQqqxProdFeeds \
  --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv

# 2. Lend Owner Safe (0x082B…E844, OP): hub + spoke reserve listing
forge script scripts/stock-listing/ListStockSummerLend3CP.s.sol:ListQqqxSummerLend3CP --rpc-url $OPTIMISM_RPC

# 3. Operating Safe (0xA6cf…AAC4, OP): DebtManager collateral, LendGateway reserve id
forge script scripts/stock-listing/ConfigureStockCashOP3CP.s.sol:ConfigureQqqxCashOP3CP --rpc-url $OPTIMISM_RPC
```

## What is deliberately out of scope

The OFT rails, the PriceRelay/OracleSink wiring, and the cash-side `PriceProviderV2` entry for an
iToken are the cash-mainnet-asset-listing repo's bundles, not this one's. This repo only ever
*reads* the price they establish; it never writes `PriceProviderV2` config, and there is no
retirement bundle here — unlike PAXG, the relay leg is permanent for every asset in this shape.
