# wSPYx + PAXG prod collateral rollout

Follow-up to 3CPs **621** (Ethereum listing) and **622** (Optimism listing), which shipped the
OFT rails and priced both assets over the PriceRelay (ETH) → OracleSink (OP) path. This bundle set:

- lists **iwSPYx** and **iPAXG** as collateral on the prod Summer Lend instance and the DebtManager,
- repoints **iPAXG** off the OracleSink onto the native Chainlink **PAXG/USD** aggregator on OP
  (`0x977CD3bC66A1FA9Fb22F9BEAA966E06996f70512`), and retires the now-dead PAXG relay leg end to end,
- removes **wSPYx and PAXG** from the Ethereum trading-account registry (TradingLens).

The wSPYx relay leg **stays live** — iwSPYx pricing on OP (cash PriceProviderV2 and the new
Summer Lend feed) is the relayed wSPYx → SPYx rate composed on Chainlink SPY/USD.

## Parameters

| | DebtManager (LTV / LT / bonus) | Summer Lend (CF / max bonus / liq fee) | Add cap |
|---|---|---|---|
| iwSPYx | 73% / 78% / 7.5% | 78% / 10% / 10% | 2,000 |
| iPAXG | 75% / 80% / 6% | 80% / 10% / 10% | 300 |

Both reserves are collateral-only (borrowable no, draw cap 0), collateral risk 0 bps, flat 0%
IR curve, 0% liquidity fee — the launch-payload house style.

Staleness: SPY/USD, the relayed wSPYx→SPYx rate, and PAXG/USD all **3 days** (the relay keeper
must poke at least every 3 days; SPY/USD is 24/5, so a US-market holiday weekend longer than 72h
reads stale — fail-closed — until reopen). PAXG/USD was originally deployed at 1 day
(`0xDc77fb41…03Be`, superseded and unused); the live feed is the 3-day `PaxgUsdFeedV2`.

## Oracle pattern vs the live instance

Checked on-chain (AaveOracle `0xe8cb…6fA8`, 2026-08-07): the CAPO batch has executed — every
rate-composed or stable reserve sits behind a cap adapter, volatile market prices (ETH, ETHFI,
OP, HYPE) are direct uncapped feeds. The new reserves follow that split with one deliberate
exception:

- **iPAXG**: direct uncapped ChainlinkPriceFeed — a volatile market price, same class as ETHFI/OP.
- **iwSPYx**: rate × SPY/USD composition, **deliberately uncapped**. On a SPY stock split or
  bonus issue the wSPYx→SPYx rate jumps by the split factor while SPY/USD drops by the same
  factor; the composed price stays continuous, but an immutable growth cap on the rate leg would
  clamp the jump and under-price every iwSPYx position by the split ratio. An unbounded
  legitimate jump makes a growth cap the wrong tool (the CAPO script's own criterion).

Note: `summer-lend-feeds.json` still records the pre-CAPO feed addresses for the launch reserves;
the live reserve sources are the cap adapters. This rollout only appends its own entries.

## Prerequisite: the relay must be live

As of 2026-08-07 the prod OracleSink has **never received a price** (`latestRoundData(wSPYx)`
reverts `PriceNotSet`; the 622 staleness windows are set, but no `PriceRelay.poke()` has shipped
anything). Until the keeper pokes, iwSPYx/iPAXG cannot be priced, `_requireLivePrice` in the
feed deploy reverts, and `DebtManager.supportCollateralToken` fails. **Get the relay keeper
poking before running any step below.**

## Run order

```sh
# 1. EOA (registered EtherFiDeployer deployer): immutable feeds on OP + manifest update
source .env && ENV=mainnet forge script scripts/wspyx-paxg/DeployWspyxPaxgProdFeeds.s.sol \
  --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv

# 2. Lend Owner Safe (0x082B…E844, OP): hub + spoke reserve listings
forge script scripts/wspyx-paxg/ListWspyxPaxgSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC

# 3. Operating Safe (0xA6cf…AAC4, OP): iPAXG repoint, PAXG sink delisting, DebtManager, gateway ids
forge script scripts/wspyx-paxg/ConfigureWspyxPaxgCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC

# 4. Operating Safe (0xA6cf…AAC4, ETH): PAXG relay retirement + TradingLens removals
forge script scripts/wspyx-paxg/RemovePaxgWspyxEthereum3CP.s.sol --rpc-url $MAINNET_RPC
```

Every generator fork-simulates its bundle (step 3 replays step 2's JSON first when the reserves
are not yet live) and asserts the post-state before the JSON is trusted.

**Execution ordering is load-bearing:**

1. Feeds must exist before the Lend Owner Safe bundle lists reserves against them.
2. The Lend Owner Safe bundle must execute before the Operating Safe OP bundle
   (`LendGateway.setReserveId` registers the ids the listing assigns).
3. The Ethereum bundle must execute **after** the OP bundle: unsubscribing PAXG first would let
   the OP sink entry go stale and brick iPAXG pricing while it still reads from the sink.
4. Simulate/execute steps 2–3 while SPY/USD is fresh (within 3 days of last market close):
   listing and `supportCollateralToken` both read the live iwSPYx price.
