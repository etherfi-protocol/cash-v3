# ZCHF + USDT0 + PAXGy prod collateral rollout (Summer Lend + Cash)

Lists **ZCHF** (Frankencoin, CHF stablecoin, native on Optimism `0xD4dD…5553`), **USDT0** (Tether
omnichain USDT, `0x01bF…1071`, symbol `USD₮0`) and **PAXGy** (Paxos "Pax Gold Yield", mainnet
`0x6c64…700e`, on Optimism as the ether.fi shadow OFT **iPAXGy** `0x5168…3cF5`, 18 decimals, whose
mainnet OFT adapter is `0x3108…b40C`)
as collateral-only reserves on the prod Summer Lend instance AND on the cash side (PriceProviderV2,
DebtManager, LendGateway). Every batch of every step is generated up front and rehearsed on a fork;
only the signing happens in sequence.

Two repos: the oracle rails + cash side live here, the Summer Lend listing lives in **aave-v4**
(`scripts/etherfi/listings/EtherfiCashCollateralListings.s.sol`), because since the timelock
migration only the EtherFiTimelock holds the configurator roles — the Timelock Safe schedules,
24h pass, the Timelock Safe executes.

## Parameters (PROPOSED unless marked live)

Staleness: every Summer Lend feed uses the **7-day** bound every live cash-v3 feed on OP carries (verified
2026-09-23: iwSPYx / iwQQQx / iwTBLLx / PAXG / SPY / QQQ / TBLL all 604800s; sink windows 7 days). The
cash PriceProviderV2 entries here also use 7 days, which is ABOVE the live stables there (USDT / USDC / EURC
2 days, iPAXG 3 days) — a deliberate choice to confirm.

| | Price (cash PriceProviderV2) | Price (Summer Lend feed) | DebtManager LTV / LT / bonus | Lend CF / max bonus / liq fee | Lend add cap |
|---|---|---|---|---|---|
| ZCHF | OracleSink `price(mainnet ZCHF)`, 6 dec, sink window 7d | `OracleSinkPriceFeed` "ZCHF / USD", 8 dec, 7-day relay bound, at `0x7445…948C` (CREATE3, salt `ZchfUsdFeed`) | 80% / 85% / 7.5% | 85% / 7.5% / 10% | **0** (listed closed; curator raises) |
| USDT0 | Chainlink USDT / USD `0xECef…F5E`, 8 dec, 7 days, stable snap (live USDT entry: 2 days) | the LIVE "Capped USDT / USD" CAPO adapter `0x7579…9025` the USDT reserve reads — no new feed | 90% / 95% / 1% (= live USDT) | 90% / 5% / 10% (= live USDT); **borrowable**, live USDC curve (kink 85%, base 3%, slopes 1.25% / 10%), fee 30%, draw cap **0** | 5,000,000 |
| USDT (live reserve) | unchanged | unchanged | unchanged | **opened for borrowing**: live USDC curve + 30% fee, draw cap **0** (explicit) | unchanged (30M) |
| PAXGy | Chainlink PAXGy / Gold Exchange Rate `0xDD12…B180` (18 dec, 7 days) x XAU / USD `0x8F7b…B8B` (8 dec, 7 days) via the XAU base entry `address(959)` | composed `ChainlinkPriceFeed` "PAXGy / USD" at `0x9B92…59c2` over "XAU / USD" at `0xf66C…c7Af` (CREATE3, salts `PaxgyUsdFeed`, `XauUsdFeed`), both 7-day bounds | 75% / 80% / 6% (iPAXG mirror) | 80% / 10% / 10% (iPAXG mirror) | **0** (listed closed; curator raises) |

ZCHF and PAXGy: collateral-only (not borrowable, draw cap 0) and LISTED CLOSED (add cap 0, raised by
the risk curator via updateSpokeAddCap, role 201), collateral risk 0, flat 0% curve, 0% liquidity fee,
receive-shares on — the launch-payload house style. Caps are not completion criteria for the scripts. USDT0 and USDT: borrowable but
OPENED CLOSED (draw cap explicitly 0, as EURC was); the risk curator (Operator Safe, role 201) raises
the cap later and that is not a completion criterion. DebtManager: collateral only (no
`supportBorrowToken`). LendGateway: `setReserveId` only (no `setSpendAsset`: whether the card may
settle a debit spend in USDT0 is a product / settlement-rails decision, see "Not in scope").

## Where things are pinned

- aave-v4 `src/etherfi/AaveV4EtherfiCash.sol`: `AaveV4EtherfiCashAssets.{ZCHF,USDT0,PAXGY}_*`,
  `AaveV4EtherfiCashCaps.*_ADD_CAP`, `AaveV4EtherfiCashCollateral.*`, `AaveV4EtherfiCashTimelock.OP_SALT_*_LISTING`
- here `scripts/zchf-usdt0-paxgy/ZchfUsdt0PaxgyProdConfig.sol` (cash side + a mirror of the aave-v4
  pins for the fork rehearsal), `scripts/zchf/ZchfProdConfig.sol` (ZCHF rails + feed)

**PAXGy**: the OFT rails are live (mainnet adapter `0x3108…b40C` -> OP shadow OFT iPAXGy `0x5168…3cF5`,
LayerZero peers verified 2026-09-23, supply 0) and the ORACLE leg is pinned on both sides (composed feed,
predicted CREATE3 address, rehearsed: PAXGy / USD $4292.25 vs XAU / USD $4289.97). Both scripts include
it in the same batches as ZCHF and USDT0. Note: `0x3108…b40C` is the ETHEREUM adapter, not the OP token.

## Live state (2026-09-23)

- [done] ZCHF relay source + PriceRelay subscription on Ethereum (`output/ConfigureZchfRelayEthereum3CP-1.json`)
- [done] ZCHF OracleSink window on Optimism (`output/ConfigureZchfSinkOP3CP-10.json`); the keeper has
  delivered: the sink holds CHF / USD 1.212591 (6 dec) under the mainnet ZCHF key
- [done] aave-v4 timelock migration phases 1–3: the timelock may send every configurator call
- [ ] USDT reserve not borrowable (curve flat, fee 0, draw cap 0); nothing on the Operator Safe
- [ ] no feed deployed yet (ZCHF / USD `0x7445…948C`, XAU / USD `0xf66C…c7Af`, PAXGy / USD `0x9B92…59c2`
  all predicted, no code); nothing scheduled on the timelock; nothing on the cash side
- [x] iPAXGy shadow OFT deployed on OP (`0x5168…3cF5`, peered to the mainnet adapter)

## Run order

Generate everything first (steps A–C need only an OP RPC; each simulates its bundle end to end on a
fork, including the steps before it that have not executed yet), then sign in order.

```sh
# ── generate (read-only, any time) ───────────────────────────────────────────────────────────────
# A. cash-v3: prove every feed (ZCHF / USD, XAU / USD, PAXGy / USD) prices end to end on a fork (no broadcast)
forge script scripts/zchf-usdt0-paxgy/DeployZchfUsdt0PaxgyProdFeeds.s.sol:DeployZchfUsdt0PaxgyProdFeeds --sig 'rehearse()' --rpc-url $OPTIMISM_RPC

# B. aave-v4: every Timelock Safe batch (schedule of every asset + the USDT opening, then execute of all)
#    plus the Operator Safe risk-curator batch (USDT curve + draw cap 0), written to output/etherfi/listings/
#    and simulated to COMPLETE in the VM
forge script scripts/etherfi/listings/EtherfiCashCollateralListings.s.sol --sig 'plan()' --rpc-url optimism

# C. cash-v3: the Operating Safe bundle (PriceProviderV2 + DebtManager + LendGateway); rehearses A
#    and B on the fork when they are not live yet
forge script scripts/zchf-usdt0-paxgy/ConfigureZchfUsdt0PaxgyCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC
#    (`--sig 'rehearse()'` writes a *.rehearsal.json with any not-yet-deployed OFT stood in by a mock: never sign that one)

# ── execute (in this order) ──────────────────────────────────────────────────────────────────────
# 1. EOA (registered EtherFiDeployer deployer): immutable "ZCHF / USD", "XAU / USD" and "PAXGy / USD" feeds on OP
#    + manifest update (idempotent: feeds already deployed are reused)
source .env && ENV=mainnet forge script scripts/zchf-usdt0-paxgy/DeployZchfUsdt0PaxgyProdFeeds.s.sol:DeployZchfUsdt0PaxgyProdFeeds \
  --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
forge script scripts/zchf-usdt0-paxgy/DeployZchfUsdt0PaxgyProdFeeds.s.sol:DeployZchfUsdt0PaxgyProdFeeds --sig 'verify()' --rpc-url $OPTIMISM_RPC   # must be green

# 2. Timelock Safe (0xd442…1166, OP, 3-of-6): output/etherfi/listings/listings-schedule.json
#    (one scheduleBatch per asset; re-run configure() in aave-v4 after step 1 to write it against live state)
forge script scripts/etherfi/listings/EtherfiCashCollateralListings.s.sol --sig 'configure()' --rpc-url optimism
#    ALSO, any time from now (independent of the timelock): Operator Safe (0x23c3…6f03, risk curator):
#    output/etherfi/listings/openings-curator.json = USDT updateInterestRateData + updateSpokeDrawCap(0).
#    Step 4 holds the USDT opening until this has landed.

# 3. wait 24h (Timelock.MIN_DELAY). Do NOT list anything else on the instance in between (asset ids drift).

# 4. Timelock Safe: output/etherfi/listings/listings-execute.json (one executeBatch per asset, in id order)
forge script scripts/etherfi/listings/EtherfiCashCollateralListings.s.sol --sig 'configure()' --rpc-url optimism   # emits it; run again after: COMPLETE

# 5. Operating Safe (0xA6cf…AAC4, OP): output/ConfigureZchfUsdt0PaxgyCashOP3CP-10.json
#    (re-run C after step 4 so the bundle is generated against the live reserve ids)
forge script scripts/zchf-usdt0-paxgy/ConfigureZchfUsdt0PaxgyCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC
```

**Ordering that matters:**

1. Step 1 before step 2: the aave-v4 script refuses to schedule an asset whose feed has no code
   (immutable feed, address final — so USDT0, whose feed is live, would go alone).
2. Step 4 only executes operations whose feed PRICES (`AaveOracle.setReserveSource` reads
   `latestAnswer()`; a dead feed reverts the whole operation) and only in asset-id order; anything
   held back stays queued and is emitted on a later run.
3. Step 5 after step 4: `LendGateway.setReserveId` reverts unless the reserve exists with that asset,
   and `DebtManager.supportCollateralToken` reads the price the same bundle configures.
4. If another asset is listed on the instance between steps 2 and 4, the queued operations can only
   revert: a canceller Safe (Admin / Operator / Timelock Safe) cancels them and step 2 is redone.

## Not in scope of these bundles (follow-ups)

- `LendGateway.setSpendAsset(USDT0, true)` — USDC / USDT / EURC are the live debit-spend assets;
  USDT0 needs settlement-rail support (SettlementDispatcher / Rain) before it can settle spends.
- Cash top-ups in USDT0 / ZCHF (TopUpFactory / TopUpDest token configs), cash-be asset metadata,
  frontend.
- Draw caps stay 0 (collateral-only); the risk curator raises add caps later via the Operator Safe /
  timelock.
- PAXGy: the OFT rate limits / TradingLens entries (cash-mainnet-asset-listing) are outside this rollout.
