# 3CP-657 — raise the Veda rate staleness bound to 7 days (Summer Lend prod, OP)

Raises the staleness bound on the four Veda vault **rate** legs of the prod Aave v4 instance from 2 days to 7 days, and rebuilds the four cap adapters that bake those legs in immutably.

**Status: NOT DEPLOYED.** This PR adds the script only. The 8 contracts have not been broadcast, so the addresses are not yet known and no `output/` manifest is committed — the dry-run manifest contains simulated addresses and is deliberately excluded. Once broadcast, the manifest lands here and the repoint bundle is queued as 3CP-secure `queued/657/` for the Lend Owner Safe at **nonce 12**.

## What changes

| leg | Veda accountant | old bound | new bound | reserve |
|---|---|---|---|---|
| sETHFI rate | `0x05A1552c…A32b` | 2d | 7d | 9 (sETHFI) |
| liquidETH rate | `0x0d05D94a…8198` | 2d | 7d | 13 (liquidETH) |
| liquidBTC rate | `0xEa23aC6D…E6b0` | 2d | 7d | 14 (liquidBTC) |
| liquidUSD rate | `0xc315D6e1…D3E7` | 2d | 7d | 15 (liquidUSD) |

Only the staleness bound changes. Each new rate leg reads the same Veda accountant as the leg it replaces; each rebuilt cap adapter reuses the same base aggregator and carries the same growth-cap snapshot and growth rate. No LTV, liquidation threshold, cap or other risk parameter is touched.

Effect: a staler vault exchange rate is accepted before a reserve fails closed.

## This is a different clock from 3CP-644

644 relaxed the **market aggregator** legs. This relaxes the **keeper** legs. They are two independent clocks and have to be sized separately — no amount of keeper diligence makes a market publish on a weekend, and no market cadence bounds when Veda chooses to run its accountant. Sizing one off the other is the mistake this split avoids.

The bound here bounds the age of the accountant's `lastUpdateTimestamp`, i.e. how long ago Veda last published a vault exchange rate.

## Why 7 days

Measured from `ExchangeRateUpdated` events over the accountants' full 137-day history:

| accountant | median gap | worst since instance live | worst ever | breaches @2d | breaches @7d |
|---|---|---|---|---|---|
| liquidETH | 23.7h | **44.64h** (2026-08-18 → 08-20) | 96.76h (2026-05-04 → 05-08) | 6 | **0** |
| liquidBTC | 23.7h | **44.64h** (2026-08-18 → 08-20) | 71.77h (2026-04-17 → 04-20) | 1 | **0** |
| liquidUSD | 23.7h | 31.29h (2026-08-15 → 08-17) | 71.77h (2026-04-17 → 04-20) | 1 | **0** |
| sETHFI | 23.7h | 31.29h (2026-08-15 → 08-17) | 170.22h (2026-05-13 → 05-21) | 4 | 2 |

The 44.64h gap on liquidETH and liquidBTC was the most recent interval before this was written, leaving **3.36h of headroom** on a 48h bound. The instance has only been live since 2026-07-30 21:59 (block 154924987), so it has not yet been exposed to the worst of that distribution — the "worst ever" gaps happened while these accountants were already running, shortly before the reserves were listed.

sETHFI is included despite 7d not covering its 170.22h worst case: it is on the same keeper and the same bound, carries the largest supply of the four ($9.47M), and leaving it at 2d while moving its three siblings would strand the biggest position on the tightest bound. Covering its worst case would need ~8d, which is a worse trade than the change it would replace.

## What it costs

Drift per day, measured from consecutive `ExchangeRateUpdated` values since the instance went live:

| reserve | drift/day (max) | mispriced if frozen the extra 5d |
|---|---|---|
| 13 liquidETH | 0.91 bps | 4.6 bps |
| 14 liquidBTC | 0.44 bps | 2.2 bps |
| 15 liquidUSD | 1.46 bps | 7.3 bps |

(The 588 bps single-update move in liquidETH's full history is the accountant's 2026-04-05 initialisation, months before this instance existed. Not representative, excluded.)

Single-digit bps of worst-case mispricing against the alternative: a breach freezes the affected holders' **entire position**, because `Spoke._processUserAccountData` prices every reserve in a user's position map with no try/catch. One stale rate reverts supply, withdraw, borrow, repay and liquidation across all of that user's collateral, not just the stale asset. Debt is currently zero on all four reserves, so there is no bad-debt path — the exposure is a liveness freeze on roughly $65M of collateral.

Read this as what it is: a **risk loosening**. After it lands, a 6-day-old vault rate is accepted as fresh for collateral valuation on these four reserves.

## Why 4 bound changes need 8 contracts

`VedaAccountantPriceFeed.rateMaxStaleness` is immutable, so a new bound means a new rate leg. Aave's cap adapters hold `RATIO_PROVIDER` immutable and their cap setters are unreachable on this instance — the ACL manager is the AccessManager, which implements neither `isRiskAdmin` nor `isPoolAdmin` (see `DeployCapoPriceAdapters._aclManager`). So a new rate leg forces a rebuild of the adapter sitting on it. Two contracts per reserve.

## The base legs are deliberately not touched

Each rebuilt adapter reuses the same `BASE_TO_USD_AGGREGATOR` it reads today. Those legs are already well provisioned, measured over 37 days:

| base leg | aggregator | max gap | bound | headroom |
|---|---|---|---|---|
| ETH/USD (reserve 13) | `0x16C04812…3f3e` | 0.34h | 48h | 47.66h |
| BTC/USD (reserve 14) | `0xF012C393…BF9f` | 0.34h | 48h | 47.66h |
| USDC/USD (reserve 15) | `0xdb5a1d83…1e78` | 24.01h | 48h | 23.99h |
| ETHFI/USD (reserve 9) | `0x9A3C9759…FF34` | — | 36h | set by 3CP-644 |

Rebuilding the ETH/USD or BTC/USD legs would also force a rebuild of reserves 5 (weETH) and 6 (eBTC), which are out of scope.

**Composed budget.** A cap adapter's price is base x rate and each leg enforces its own bound, so worst-case served age is their sum: 48h + 7d = 9 days for reserves 13/14/15, and 36h + 7d for reserve 9. The rate clock (7d) is the binding one for operational alarms — set the keeper alarm against 7 days, not 9.

## Cap parameters

Carried forward from the CAPO rollout, read off the live adapters at deploy time and asserted equal to the reviewed values rather than restated. Read at block 155828059:

| adapter | snapshot ratio | snapshot ts | growth | isCapped |
|---|---|---|---|---|
| sETHFI | `1187971295403462986` | `1780627963` | 12.00% | false |
| liquidETH | `1094734190917310748` | `1780627963` | 5.00% | false |
| liquidBTC | `1029351010000000000` | `1780627963` | 3.00% | false |
| liquidUSD | `1160589000000000000` | `1780627963` | 7.50% | false |

All four sit 76.7 days back, inside Aave's `[now-180d, now-7d]` window (`MINIMUM_SNAPSHOT_DELAY` 604800, `MAXIMUM_SNAPSHOT_TERM` 15552000). Valid for another ~103 days; past that the script refuses to run and a re-snapshot plus risk review is required.

## Out of scope, on purpose

- **Reserves 16 (liquidRESERVE) and 18 (liquidRWA) are already at 7 days and stay there.** Their Midas push feeds show max gaps of 143.59h and 148.78h, so 7d is correct and a *tighter* bound would breach. A 5-day bound, which was the original ask, would have broken both.
- **Reserve 7 (eUSD)** shares the 2d Veda bound but has zero supply. Not worth two deploys on a dormant reserve.
- **Reserve 6 (eBTC)** shares the bound and its worst-ever gap is **624.04h** — the worst on the instance. It holds $223K and its growth cap is deliberately loose for that reason. 7d does not cover a 26-day gap, so it needs its own decision rather than being bundled in.

## Testing

Every check runs on a mainnet fork before the script writes any JSON. Verified green at block 155828059:

- **Exact price equality** on all four reserves — new source and live oracle agree to the wei, not within a tolerance. With the same base aggregator, same accountant and same snapshot at the same block there is no legitimate source of drift.
- **Cap is a clone, not a re-tune** — snapshot ratio, timestamp, growth percent, derived growth-per-second and ratio decimals all asserted equal to the live adapter's.
- **Live state matches what the change assumes** — each live rate leg's accountant *and* its exact current bound, plus each live cap's snapshot. A source or cap that has already moved fails the run rather than being rebuilt from something unreviewed.
- **Dress rehearsal** — the 4-call repoint batch replays on the fork **as the Owner Safe**, verifies the post-state field by field, then rolls back and asserts the rollback. Pranking as the Safe bypasses the signature threshold but not the configurator's role check, so a green rehearsal is real proof the Safe holds role 400.
- **The bound actually moved, both directions.** At 3 days stale the new source prices *and the old source reverts* `StalePrice` — that second half is what proves the 2d bound was genuinely binding and this run is the fix rather than a no-op. At exactly 7 days the new source still prices (the comparison is a strict `>`; an off-by-one would be invisible from the "eventually reverts" side). At 7 days + 1 second it reverts.
- **The clock under test is isolated.** The base leg is mocked to its live value during the warps, so the assertions cannot pass because the 48h *base* bound tripped first — the frozen-fork-timestamp trap. The boundary is computed from each accountant's own `lastUpdateTimestamp`, not from `now`, because that is what the feed actually compares against; warping to `now + 7 days` overshoots by however stale the rate already is and reads as a spurious failure.
- **Non-vacuity confirmed by mutation.** Three deliberate breakages, each caught by a distinct assertion:

  | mutation | assertion that fired |
  |---|---|
  | keep the old 2d bound on the new leg | `new rate bound did not take` |
  | liquidETH growth 500 → 600 | `live growth percent is not the reviewed value` |
  | liquidBTC leg → liquidETH's accountant | `live rate leg reads a different accountant` |

`verifyLive()` is shared between the rehearsal and the post-execution check (`--sig 'verifyLive()'`). It asserts properties rather than deployed addresses, so it cannot be satisfied by a source that merely happens to sit at an expected address, and returns a count so a zero-iteration pass cannot read as success.

## Running it

Dry run first — it executes every assertion above without spending gas:

```sh
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RelaxVedaRateStalenessBounds.s.sol:RelaxVedaRateStalenessBounds \
  --rpc-url $OPTIMISM_RPC --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e -vvv
```

Then broadcast and verify:

```sh
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RelaxVedaRateStalenessBounds.s.sol:RelaxVedaRateStalenessBounds \
  --rpc-url $OPTIMISM_RPC --account etherfi-deployer \
  --sender 0xf8a86ea1Ac39EC529814c377Bd484387D395421e \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
```

**Deployer.** `0xf8a86ea1Ac39EC529814c377Bd484387D395421e` is the CAPO-rollout deployer: it created 7 of the 8 contracts this change replaces, consecutively at nonces 72–78. Confirmed by deriving `keccak(rlp([sender, nonce]))[12:]` across its nonce range and matching the live addresses, rather than trusting an explorer. Estimated cost is 7,392,696 gas, about 0.0000074 ETH at current OP gas prices.

After the Owner Safe executes the repoint batch, one command asserts the whole post-state (returns the number of reserves checked; before execution it fails on the first bound, which is expected):

```sh
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RelaxVedaRateStalenessBounds.s.sol:RelaxVedaRateStalenessBounds \
  --sig 'verifyLive()' --rpc-url $OPTIMISM_RPC -v
```

## Execution note for the Safe batch

`AaveOracle.setReserveSource` prices the new source in the same transaction (`AaveOracle.sol:49`), so the batch **reverts atomically if any rate is past 7 days at execution time**, and a failed execution burns nonce 12 plus every collected signature. Execute while the keeper is fresh.

## Rollback

The replaced sources stay deployed and untouched — the batch only moves a pointer. Reverting is the same 4 calls with the previous addresses. No state is destroyed and no position is affected in either direction.
