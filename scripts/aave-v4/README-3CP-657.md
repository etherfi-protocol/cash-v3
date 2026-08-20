# 3CP-657 — raise every staleness bound to a 7-day floor (Summer Lend prod, OP)

Raises **every** price-feed staleness bound on the prod Aave v4 instance to a uniform minimum of 7 days, and rebuilds every cap adapter that bakes a changed leg in immutably.

**Status: NOT DEPLOYED.** Script only. The 37 contracts have not been broadcast, so no `output/` manifest is committed — the dry-run manifest holds simulated addresses. Once broadcast, the repoint bundle is queued as 3CP-secure `queued/657/` for the Lend Owner Safe at **nonce 12**.

## Scope

Derived by walking all 23 reserves' sources down to the leaves, not from a manifest. The instance carries **29 bounded legs**; **25 sit below 7 days**. Rebuilding those forces a rebuild of the **12 cap adapters** above them, and **20 of 23 reserves** get repointed.

| | count |
|---|---|
| new legs | 25 |
| rebuilt cap adapters | 12 |
| **total new contracts** | **37** |
| reserves repointed | 20 |

Untouched: reserves **16** (liquidRESERVE), **17** (weEUR), **18** (liquidRWA) — already at 7d throughout. Their legs (`liquidRESERVE/USD rate`, `liquidRWA/USD rate`, `weEUR/EUR rate`, `EUR/USD`) are the four already at or above the floor.

### Legs by current bound

| bound | legs | examples |
|---|---|---|
| 36h | 3 | ETHFI/USD, HYPE/USD, OP/USD |
| 48h | 16 | ETH/USD (x2), BTC/USD, USDC/USD, USDT/USD, EURC/USD, frxUSD/USD, weETH/ETH, beHYPE/HYPE, and the 6 Veda rate legs |
| 72h | 6 | SPY/USD, QQQ/USD, TBLL/USD, PAXG/USD, and the 3 xStock sink feeds |

## Rationale, and the limit of it

The operating decision is that **price-feed health is monitored actively off chain and acted on regardless of the on-chain bound**, so the bound is a backstop rather than the primary control. Under that model a uniform 7d floor removes a class of self-inflicted liveness outages: a merely-late feed no longer fails a reserve closed, and every asset browns out on the same schedule instead of a different one per leg.

The cost is real and is recorded here so it is not rediscovered later.

**Keeper legs (Veda accountants) — the exposure is tiny and this is a clear win.** Those rates are monotone accruals drifting <1.5 bps/day, so a frozen rate held the extra days mis-prices by single-digit bps. These are also the legs with a genuine observed problem:

| accountant | worst gap | breaches @48h | breaches @7d |
|---|---|---|---|
| eBTC | **624.04h** | 5 | 2 |
| sETHFI | 170.22h | 4 | 1 |
| liquidETH | 96.76h | 6 | **0** |
| liquidBTC | 71.77h | 1 | **0** |
| liquidUSD | 71.77h | 1 | **0** |
| eUSD | 71.77h | 2 | **0** |

eBTC and sETHFI still breach at 7d. For them 7d is a strict improvement, not a fix — eBTC's keeper needs an SLA conversation with Veda.

**Market legs — no observed problem, and a materially larger backstop window.** None of the market aggregators has ever breached even its current bound (max observed gap **0.34h** on ETH/USD and BTC/USD against 48h). Widening them is not fixing anything; it is accepting a larger window in exchange for uniformity. For a genuinely dead feed, the mispricing served equals the worst adverse move over the window, measured on ~150 days of history:

| feed | worst move @48h | @7d | delta |
|---|---|---|---|
| ETHFI/USD | 28.48% | **54.84%** | +26.36pp |
| HYPE/USD | 27.79% | 34.28% | +6.49pp |
| ETH/USD | 23.48% | 26.24% | +2.76pp |
| OP/USD | 19.03% | 19.74% | +0.71pp |
| BTC/USD | 13.73% | 16.71% | +2.98pp |

Against bad-debt tolerance `1 - 1/(1+bonus)` from the LT trigger: **13.04%** on liquidETH/liquidBTC (CF 70%, bonus 1.150x), **6.98%** on liquidUSD/eUSD (CF 90%, 1.075x), **16.67%** on sETHFI (CF 40%, 1.200x).

So on a dead market feed a 7d bound can serve a stale price past the point where liquidations stop covering the position. **This design relies on the off-chain monitor catching a dead feed long before 7 days.** That is the accepted trade, stated explicitly rather than buried.

## Why a redeploy and not a setter

`rateMaxStaleness` is immutable on all three of our feed types (`ChainlinkPriceFeed`, `VedaAccountantPriceFeed`, `OracleSinkPriceFeed`), and Aave's cap adapters hold their legs immutable with the cap setters permanently unreachable on this instance — the ACL manager is the AccessManager, which implements neither `isRiskAdmin` nor `isPoolAdmin`. A new bound needs a new leg, and a new leg needs a rebuild of every adapter sitting on it.

## Nothing but the bound changes

Every new leg wraps the same aggregator / accountant / sink+token as the leg it replaces, carries its description across verbatim, and keeps `isStableToken` and the rate precision identical. Every rebuilt adapter reuses the same siblings and carries the same cap parameters forward, read off the live adapter rather than restated.

**Shared legs are deployed once and reused**, so the pre-change sharing graph is preserved exactly:

| leg | shared by |
|---|---|
| ETH/USD `0x62B6153a…0d16` | 5 weETH, 13 liquidETH |
| BTC/USD `0x7F5276E0…Ac50` | 6 eBTC, 14 liquidBTC |
| USDC/USD `0xADfA1a2B…a19b` | 0 USDC, 15 liquidUSD |
| ETHFI/USD `0x53c3d3c3…fFc9` | 8 ETHFI, 9 sETHFI |
| HYPE/USD `0xB41cE833…7D82` | 11 wHYPE, 12 beHYPE |

Duplicate legs that exist today are kept duplicated rather than consolidated — reserve 1 (WETH) reads its own ETH/USD leg `0xCFe45EF2…3ca3`, distinct from the one weETH/liquidETH read. Consolidating them would be a wiring change beyond this batch.

The three xStock sink feeds compose an underlying USD leg that this batch also replaces, so each new sink feed is pointed at the **new** underlying.

## Testing

Every check runs on a mainnet fork before the script writes any JSON. Verified green at block ~155831000:

- **Exact price equality on all 20 reserves** — every new source and the live oracle agree to the wei, not within a tolerance. Also asserted per-leg, so a mis-wired leg fails before its adapter is even built.
- **Caps are clones, not re-tunes** — snapshot ratio, timestamp, growth percent, derived growth-per-second and ratio decimals asserted equal to the live adapter's; par caps and cap ratios likewise.
- **Dress rehearsal** — all 20 repoints execute as the Owner Safe against the real instance and real roles, post-state verified, then rolled back with the rollback asserted. Pranking as the Safe bypasses the signature threshold but not the configurator's role check, so a green rehearsal proves the Safe holds role 400.
- **The bound moved, proven on all 25 legs, both directions.** Per leg: warp just past its **own old** bound and assert the old leg reverts while the new one still prices; then assert the new leg prices at exactly 7d and reverts at 7d+1s. Output: `bound proven on 25 of 25 legs`.
- **Post-state check walks the live graph**, not a hardcoded list, so a leg left behind below the floor is caught even if it was never in scope. Returns a count so a zero-iteration pass cannot read as success.

### Two traps this had to dodge

1. **A composing leg's binding edge is the oldest timestamp in its chain, not its own.** The sink feeds enforce their own bound *and* their underlying's, so measuring from the sink's timestamp alone overstates the surviving window — this surfaced as a real failure (`iwQQQx / USD: NEW leg reverts exactly AT the target`) and is fixed by taking the minimum across the chain.
2. **The post-state floor must be an independent literal.** `verifyLive` originally asserted `>= TARGET`, so lowering `TARGET` moved the setter and the assertion together — setting `TARGET = 5 days` produced a **fully green run**. `REQUIRED_FLOOR = 604800` is now pinned separately; the same mutation is caught.

### Non-vacuity confirmed by mutation

| mutation | assertion that fired |
|---|---|
| shared ETH/USD leg not reused (sharing graph broken) | `leg below the 7d floor: 0x62B6153a…0d16 bound=172800` |
| sink feed left pointing at the old 72h underlying | `leg below the 7d floor: 0x045ACc54…4C38 bound=259200` |
| `TARGET = 5 days` | `leg below the 7d floor: … bound=432000` |

## Running it

Dry run first — executes every assertion above without spending gas:

```sh
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RaiseAllStalenessBoundsTo7d.s.sol:RaiseAllStalenessBoundsTo7d \
  --rpc-url $OPTIMISM_RPC --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e -vvv
```

Then broadcast and verify:

```sh
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RaiseAllStalenessBoundsTo7d.s.sol:RaiseAllStalenessBoundsTo7d \
  --rpc-url $OPTIMISM_RPC --account etherfi-deployer \
  --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
```

**Deployer.** `0xf8a86ea1Ac39EC529814c377Bd484387D395421e` is the CAPO-rollout deployer: it created 7 of the contracts this replaces, consecutively at nonces 72–78. Confirmed by deriving `keccak(rlp([sender, nonce]))[12:]` across its nonce range and matching live addresses, rather than trusting an explorer.

After the Owner Safe executes:

```sh
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RaiseAllStalenessBoundsTo7d.s.sol:RaiseAllStalenessBoundsTo7d \
  --sig 'verifyLive()' --rpc-url $OPTIMISM_RPC -v
```

## Execution note for the Safe batch

`AaveOracle.setReserveSource` prices the new source in the same transaction (`AaveOracle.sol:49`), so the batch **reverts atomically if any source is stale at execution time**, and a failed execution burns nonce 12 plus every collected signature. With 20 calls in one batch the surface is wider than a 4-call batch: execute while the Veda keepers are fresh, and prefer a trading day so the 24/5 equity feeds (SPY, QQQ, TBLL) are publishing.

## Rollback

The replaced sources stay deployed and untouched — the batch only moves pointers. Reverting is the same 20 calls with the previous addresses. No state is destroyed and no position is affected in either direction.

## Relationship to 3CP-644

644 relaxed four **market** legs (ETHFI, HYPE, OP to 36h; EUR to 7d). This raises everything, including those, to a 7d floor. The two share the deploy-and-repoint pattern; the difference is that 644 sized each bound against its own feed's cadence, while this applies a uniform floor as a monitoring-backed policy.
