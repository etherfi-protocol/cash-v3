# iwQQQx prod collateral rollout

Follow-up to the two **cash-mainnet-asset-listing** bundles (Ethereum + Optimism, PR TBD), which
ship the OFT rails and price wQQQx over the PriceRelay (ETH) → OracleSink (OP) path: the iwQQQx
ShadowOFT on Optimism, and a relayed wQQQx → QQQx rate keyed by the mainnet wQQQx address. This
bundle set lists **iwQQQx** as collateral on the prod Summer Lend instance and the DebtManager.

There is no PAXG-style oracle repoint or retirement here — the wQQQx relay leg is **permanent**.
iwQQQx pricing on OP (both the cash `PriceProviderV2` and the new Summer Lend feed) is the relayed
wQQQx → QQQx rate composed on Chainlink QQQ/USD, indefinitely.

## Parameters

| | DebtManager (LTV / LT / bonus) | Summer Lend (CF / max bonus / liq fee) | Add cap |
|---|---|---|---|
| iwQQQx | 73% / 78% / 7.5% | 78% / 10% / 10% | 2,000 |

Collateral-only (borrowable no, draw cap 0), collateral risk 0 bps, flat 0% IR curve
(`optimalUsageRatio` 99%, all rate-growth params 0), 0% liquidity fee — the same collateral-only
house style used for iwSPYx.

## Staleness

QQQ/USD and the relayed wQQQx → QQQx rate are both **3 days** on the Aave v4 feed leg
(`DeployQqqxProdFeeds`). The relay keeper must poke **at least every 3 days** — this is the
binding cadence, tighter than the OracleSink's own 7-day window. QQQ/USD is a 24/5 feed, so a
US-market holiday weekend longer than 72h reads stale (fail-closed, on both the cash and lend
sides) until reopen.

## Why iwQQQx is deliberately uncapped

Every other rate-composed reserve on the live Summer Lend instance sits behind a
`CLRatePriceCapAdapter`. iwQQQx does not, and should not: on a Nasdaq-100 constituent split or a
QQQ share split, the wQQQx → QQQx rate jumps by the split factor while QQQ/USD drops by the same
factor. The composed price stays continuous, but an immutable growth cap on the rate leg would
clamp that jump and under-price every iwQQQx position by the split ratio, with no way to
re-snapshot an immutable cap. A legitimate unbounded jump makes a growth cap the wrong tool —
the same reasoning applied to iwSPYx. Direct feeds like iPAXG's are not applicable here: iwQQQx
has no independent USD market price to feed from, only the relayed 4626 rate.

## Prerequisite, stated loudly: the OracleSink has never held a wQQQx price

As of 2026-08-09 the prod OracleSink holds **no** wQQQx entry, and the iwQQQx ShadowOFT on
Optimism does not exist — the cash-mainnet-asset-listing Ethereum bundle has not executed, and
its Optimism bundle (which deploys the ShadowOFT and writes the cash-side `PriceProviderV2` entry)
has not either. Until the Ethereum bundle executes and the relay keeper pokes:

- `_requireLivePrice` in `DeployQqqxProdFeeds` reverts on the iwQQQx feed,
- `DebtManager.supportCollateralToken` reverts (it reads the iwQQQx price through
  `PriceProviderV2`, whose entry the other repo's Optimism bundle writes).

Every generator here still **generates and fork-rehearses** regardless, via
`_rehearseQqqxRails()` (deploys the real iwQQQx ShadowOFT through the real factory/salt, and seeds
a relayed sink price by writing directly into the sink's storage) and, in
`ConfigureQqqxCashOP3CP` specifically, a fork-only prank of the Operating Safe through the real
`PriceProviderV2.setTokenConfig` reproducing the other repo's exact Task A3 config. Both are
fork-only, logged loudly (`[REHEARSAL]`), and never emitted as calldata in either bundle below —
they exist purely so this repo's scripts can be authored and rehearsed without waiting on the
other repo's PR to merge and execute.

## Run order

```sh
# 1. EOA (registered EtherFiDeployer deployer): immutable feeds on OP + manifest update
source .env && ENV=mainnet forge script scripts/qqqx/DeployQqqxProdFeeds.s.sol \
  --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv

# 2. Lend Owner Safe (0x082B…E844, OP): hub + spoke reserve listing
forge script scripts/qqqx/ListQqqxSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC

# 3. Operating Safe (0xA6cf…AAC4, OP): DebtManager collateral, LendGateway reserve id
forge script scripts/qqqx/ConfigureQqqxCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC
```

Every generator fork-simulates its own bundle (step 3 replays step 2's JSON first when the
reserve is not yet live) and asserts the post-state before the JSON is trusted.

**Execution ordering is load-bearing:**

1. The feeds (step 1) must exist and price before the Lend Owner Safe bundle lists a reserve
   against them.
2. The Lend Owner Safe bundle (step 2) must execute before the Operating Safe OP bundle (step 3):
   `LendGateway.setReserveId` registers the reserve id step 2 assigns.
3. Simulate and execute steps 2–3 while QQQ/USD is fresh (within 3 days of last market close) —
   both the reserve listing and `supportCollateralToken` read the live iwQQQx price.
4. Real execution of every step above additionally requires the cash-mainnet-asset-listing
   Ethereum bundle to have executed and the relay keeper to have poked at least once — see the
   prerequisite section above.

## What is deliberately out of scope

The OFT rails, the PriceRelay/OracleSink wiring, and the cash-side `PriceProviderV2` entry for
iwQQQx are the cash-mainnet-asset-listing repo's bundles, not this one's. This repo only ever
*reads* the price they establish; it never writes `PriceProviderV2` config, and there is no
retirement bundle here — unlike PAXG, the wQQQx relay leg is permanent.
