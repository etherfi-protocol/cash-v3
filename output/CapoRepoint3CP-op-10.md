# 3CP — repoint the ether.fi Cash Aave V4 price feeds onto capped adapters

**Chain** Optimism (10) · **Safe** `0x082B85ED50F1cd120C597EF860ece712e54CE844` (Owner Safe, 2-of-6)
**Batch file** `output/CapoRepoint3CP-op-10.json` · **17 transactions** · **PR** etherfi-protocol/cash-v3#258

## What this does

Repoints 17 of the 19 reserves on the Cash Spoke from their current price feeds onto newly deployed
capped adapters. Nothing else changes: no listings, no caps, no roles, no parameters.

Aave's review of this market said our price feeds were "directly plugged in as is, without using a
Price Adapter." Most already were our own adapters, but the concern underneath was correct: eleven
reserves priced off an exchange rate with **no bound on how fast that rate could rise**. If a Veda
accountant or Midas NAV publisher posted a bad number, it became collateral value in the same block.

After this batch, 15 of 19 reserves are capped, all Pyth exposure is gone, and the ±1% snap-to-$1 on
stables is replaced by Aave's upside-only cap.

## The transactions

All 17 are identical in shape:

| Field | Value |
| --- | --- |
| Target | `0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b` (SpokeConfigurator) |
| Function | `updateReservePriceSource(address spoke, uint256 reserveId, address priceSource)` |
| Selector | `0x7f1e3675` |
| `spoke` | `0xdffcC3536D932eb51Df51a7F5FA407c4270d5308` |
| Value | 0 |
| Operation | 0 (CALL, not delegatecall) |
| Required role | 400, held by the Owner Safe only — the Operator Safe cannot do this |

WETH (reserve 1) and OP (reserve 10) are deliberately **not** in the batch. Their feeds are already
Chainlink-rooted, staleness-checked and non-snapping, so repointing them would change nothing.

## Before and after

| # | Asset | Current source | New adapter | Price now | Price after | Δ | Supplied |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | USDC | `0x87C74C…4ED7` | `0xE55eac…8C69` | 100000000 | 99975787 | -2 bps | 6000000 |
| 2 | USDT | `0x3Fe467…b89c` | `0x6a6B25…Fc92` | 100000000 | 99894058 | -11 bps | 0 |
| 3 | EURC | `0xDb2A51…742c` | `0xcBF18F…33A0` | 115038246 | 115038246 | +0 bps | 0 |
| 4 | frxUSD | `0x14a2Aa…5283` | `0x859c12…CC31` | 100014846 | 100014846 | +0 bps | 0 |
| 5 | weETH | `0x9e1cAf…09aC` | `0x81ED13…3fd9` | 204739185761 | 204739185761 | +0 bps | 0 |
| 6 | eBTC | `0x0fdF97…6488` | `0xFa80bA…860f` | 6393910879530 | 6393910879530 | +0 bps | 0 |
| 7 | eUSD | `0x106399…aD63` | `0xD617E1…751b` | 106572023 | 106572023 | +0 bps | 0 |
| 8 | ETHFI | `0x823d8D…Daba` | `0x89AB0B…8a80` | 39833150 | 39743942 | -22 bps | 0 |
| 9 | sETHFI | `0x14c760…4b13` | `0xaF8749…d322` | 47846710 | 47739556 | -22 bps | 0 |
| 11 | wHYPE | `0x961f6a…a67F` | `0x7405E1…1B22` | 5428620300 | 5428620300 | +0 bps | 0 |
| 12 | beHYPE | `0x259992…9Fb8` | `0xefeDBa…cA50` | 5520975828 | 5530244809 | +17 bps | 0 |
| 13 | liquidETH | `0x4829C1…0eCD` | `0x48420d…add1` | 204918195002 | 204918195002 | +0 bps | 0 |
| 14 | liquidBTC | `0xc5b599…23b3` | `0xD60ec8…77C7` | 6576436852686 | 6576436852686 | +0 bps | 0 |
| 15 | liquidUSD | `0x7E916F…E38C` | `0x17DdE0…1451` | 117033700 | 117005362 | -2 bps | 0 |
| 16 | liquidRESERVE | `0x6D7b37…b0CB` | `0x6b5C61…29BC` | 102596410 | 102596410 | +0 bps | 0 |
| 17 | weEUR | `0x4fdc1B…9f26` | `0x7605db…A567` | 116601750 | 116597299 | -0 bps | 0 |
| 18 | liquidRWA | `0x6148eE…0154` | `0x6Bf29C…2854` | 101185637 | 101185637 | +0 bps | 0 |


Every price is read live. The three non-zero moves are all expected and none is a correctness change:

- **USDC −2 bps, USDT −11 bps** — the old feeds snapped anything within 1% of $1 to exactly
  `100000000`. The new ones report the real Chainlink price and cap only the upside at $1.04. This is
  the intended fix; USDC is the borrowable asset, so it now prices slightly *below* par as it should.
- **ETHFI and sETHFI −22 bps** — provider switch from Pyth to Chainlink on a volatile asset. sETHFI
  inherits it through its ETHFI leg.
- **beHYPE +17 bps** — same, Pyth to Chainlink.

Exposure at risk: **6 USDC supplied across the whole market and zero debt.** No position can be
harmed by these price changes.

## Deployed adapters

Deployer `0xf8a86ea1Ac39EC529814c377Bd484387D395421e`, 36 CREATE transactions, all successful, all
source-verified on OP Etherscan.

| Asset | Adapter |
| --- | --- |
| ETHFI | `0x89AB0BeEF8f88933f4724a2D0C4a149c644a8a80` |
| wHYPE | `0x7405E1C9a5AdC2A1730f38186f5845EC54Cd1B22` |
| USDC | `0xE55eacdC1EC9dA0f33B9CEa7D136a47CC6008C69` |
| USDT | `0x6a6B2529c1BC14f0A062D7903B4894B477BfFc92` |
| frxUSD | `0x859c126dad6952a798ecdc5c06f7063B8a9FCC31` |
| EURC | `0xcBF18F68e2aBd480231241fa97BD41aE556433A0` |
| weETH | `0x81ED135fc10FF855202E582d8cfd50E8A5533fd9` |
| beHYPE | `0xefeDBa79436767AAfcF7902C66383d4735DacA50` |
| liquidRESERVE | `0x6b5C6155A07A5E3af6591d48571FC1BdFEc929BC` |
| liquidRWA | `0x6Bf29C9bec671EE7787352EBc42c2151a7BC2854` |
| weEUR | `0x7605dbe2948C99a559B9a065881916Ef043dA567` |
| eBTC | `0xFa80bA4b7aC946F3b45DC8ED537b1BEbD8eC860f` |
| liquidBTC | `0xD60ec8fCba09c7642099eA89A9D58721B00277C7` |
| liquidETH | `0x48420d702a3190235B5A5D123ca82f876752add1` |
| liquidUSD | `0x17DdE04d8Ff1024D3076944658ED9B6bd5F51451` |
| sETHFI | `0xaF8749C3DC1Fc0592f21c2593204C45D3bE0d322` |
| eUSD | `0xD617E1D59aA992D985c07ADC48c36aD2a00E751b` |

Architecture per asset, bottom to top:

```
raw Chainlink aggregator / Veda accountant / Midas NAV proxy
  -> ChainlinkPriceFeed or VedaAccountantPriceFeed   (ours, Paladin-audited: staleness,
                                                      fails closed, normalises decimals)
    -> Aave price cap adapter, unmodified             (growth cap or fixed cap)
      -> AaveOracle                                   (requires 8 decimals, price > 0)
```

**No new contract was written for this.** Every capping contract is Aave's own, vendored verbatim
from `aave-dao/aave-price-feeds` @ `ff9f24a7`. Every leg beneath one is an instance of an
already-audited cash-v3 feed. Nothing here required a new audit.

## Verification already performed on chain

| Check | Result |
| --- | --- |
| All 17 adapters have code and report `decimals() == 8` | pass — AaveOracle would reject otherwise |
| All 17 return a positive price within 500 bps of the live oracle | pass, max 36 bps |
| No growth cap is binding on day one | pass — `isCapped() == false` on all 11 |
| Growth caps match the risk-approved values exactly | pass, 0 mismatches |
| Stable caps are $1.04; EURC ratio is 1.04 | pass |
| `ACL_MANAGER` is this instance's AccessManager on every adapter | pass |
| `setCapParameters` / `setPriceCap` revert even from the Owner Safe | pass — caps are immutable |
| Each batch transaction decodes to the right reserve and adapter | pass, 17/17 |
| Live oracle source still matches the feed each adapter replaces | pass — no drift since deployment |
| Etherscan source verification | pass, 17/17 |

## Risks

**A cap binding does not revert.** The adapter clamps the ratio and returns a lower price, so health
factor, borrow power and liquidations all keep computing. The harm would be economic: collateral
under-priced until the ceiling catches up, which understates health factors. None is binding now, and
the smallest headroom in the set is beHYPE at ~4 days of publishing gap.

**Staleness does revert**, and that is deliberate — a stale price is worse than no price. If a source
goes stale or a Veda accountant pauses, operations on that reserve fail closed, including liquidating
positions that hold it. Bounds are set from measured cadence: 2 days against a 4–6 hour Veda cadence,
7 days against a Midas cadence of up to 3.9 days observed.

**The caps are immutable.** Changing one means deploying a fresh adapter and a second repoint batch.

**Known, accepted:** eUSD's vault is denominated in USDe and there is no USDe/USD feed on OP, so its
base leg is a fixed $1. The feed live today already makes that assumption silently; this makes it
explicit and growth-capped, but a USDe depeg still would not show.

## Rollback

The current feeds stay deployed and untouched — this batch only changes a pointer. Reverting is the
same 17 calls with the `replaces` column from the table above as the third argument. No state is
destroyed and no position is affected in either direction.

## Post-execution verification

1. For each reserve in the table, `AaveOracle.getReserveSource(id)` returns the new adapter.
2. For each reserve, `AaveOracle.getReservePrice(id)` returns a positive price matching the "Price
   after" column within normal market movement.
3. `isCapped()` is still false on all 11 growth-cap adapters.
4. `Spoke.getReserveCount()` is still 19 and no reserve reverts on a price read.

A script that runs all four is in the pull request.
