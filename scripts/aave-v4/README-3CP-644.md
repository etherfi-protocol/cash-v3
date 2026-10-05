# 3CP-644 — update oracle staleness bounds (Summer Lend prod, OP)

Updates the price oracles on the prod Aave v4 instance to use looser staleness bounds.

**Status: deployed 2026-08-13.** All 8 contracts are live on OP Mainnet and Etherscan-verified. The repoint bundle is queued as [3CP-secure#644](https://github.com/etherfi-protocol/3CP-secure/pull/644) for the Lend Owner Safe at nonce 11, safeTxHash `0x74c04f86e0e66d94d76ed3bf55cdc5d665409af6d73c03d992fceb6140994f65`. Nothing is repointed until that batch executes.

## What changed

| leg | Chainlink aggregator | old bound | new bound | reserves |
|---|---|---|---|---|
| ETHFI / USD | `0x9A3C9759…FF34` | 6h | 36h | 8 (ETHFI), 9 (sETHFI) |
| HYPE / USD | `0x961f6a07…D67F` | 6h | 36h | 11 (wHYPE), 12 (beHYPE) |
| OP / USD | `0x0D276FC1…9246` | 24h | 36h | 10 (OP) |
| EUR / USD | `0x36263698…9F20` | 2d | 7d | 3 (EURC), 17 (weEUR) |

Only the staleness bound changed. Each new leg wraps the same Chainlink aggregator as the leg it replaces; each rebuilt cap adapter reuses the same ratio provider and carries the same growth-cap snapshot and growth rate. No LTV, liquidation threshold, cap or other risk parameter is touched.

Effect: a staler price is accepted before a reserve fails closed.

## Deployed

| Contract | Address | Replaces |
|---|---|---|
| ETHFI/USD leg, 36h | `0x53c3d3c36cae804E6B639cA2600662aF51B4fFc9` | `0x89AB0BeEF8f88933f4724a2D0C4a149c644a8a80` |
| HYPE/USD leg, 36h | `0xB41cE833937aEf200B77fa796bADED2F6Bea7D82` | `0x7405E1C9a5AdC2A1730f38186f5845EC54Cd1B22` |
| OP/USD leg, 36h | `0x3b79488486f0aD5F05a66Ad377E25b829fff2bD5` | `0x6D53a69EBC75cFeDf319F77569a4F732f75AED79` |
| EUR/USD leg, 7d | `0x4E97B65C568f94fDF653324EfF5841417cEA3C50` | base leg only, not a reserve source |
| sETHFI cap adapter | `0xd452ca984E0606297bCb430e076087F126e24a38` | `0xaF8749C3DC1Fc0592f21c2593204C45D3bE0d322` |
| beHYPE cap adapter | `0xc6d0023679769A532879AE50E57F40aB628201E7` | `0xefeDBa79436767AAfcF7902C66383d4735DacA50` |
| weEUR cap adapter | `0xFA239571dDa672A935Fb7962513b37b1CfF280cb` | `0x7605dbe2948C99a559B9a065881916Ef043dA567` |
| EURC cap adapter | `0xC1Cf424A5d58BB943aDbA7fF3E1E1D2e354C2CD1` | `0xcBF18F68e2aBd480231241fa97BD41aE556433A0` |

## Why 8 contracts for 4 bound changes

`ChainlinkPriceFeed.rateMaxStaleness` is immutable, so a new bound means a new leg. Aave's cap adapters hold `BASE_TO_USD_AGGREGATOR` immutable and their cap setters are unreachable on this instance — the ACL manager is the AccessManager, which implements neither `isRiskAdmin` nor `isPoolAdmin` (see `DeployCapoPriceAdapters._aclManager`). So a new leg forces a rebuild of every adapter sitting on it: sETHFI, beHYPE, weEUR, EURC.

## Cap parameters

Carried forward from the CAPO rollout, read off the live adapters at deploy time and asserted equal to the reviewed values rather than restated:

| adapter | ratio provider (reused) | snapshot ts | growth |
|---|---|---|---|
| sETHFI | `0xb1F53B6a…5d7E` | `1780627963` | 12.00% |
| beHYPE | `0xcd0D452c…FD96` | `1785344431` | 3.00% |
| weEUR | `0x982F860B…5aAf` | `1780627963` | 9.00% |
| EURC | asset leg EURC/USD reused | par cap `1.04e8` | n/a |

Aave's `PriceCapAdapterBase` rejects a snapshot older than 180 days. That bounded the deploy window (sETHFI and weEUR to ~2026-12-01, beHYPE to ~2027-01-25); it does not affect already-deployed adapters. The script checks the window and refuses to deploy rather than reverting inside Aave's constructor.

## Verification

Because the aggregator, ratio provider and snapshot are identical, each new source must price **exactly** equal to the one it replaces — asserted at equality, not a tolerance:

```
ok ETHFI  reserve=8   price=38349406      ok beHYPE reserve=12  price=5870575661
ok wHYPE  reserve=11  price=5760070700    ok weEUR  reserve=17  price=116964810
ok OP     reserve=10  price=8684862       ok EURC   reserve=3   price=115256774
ok sETHFI reserve=9   price=46064469
```

The script also asserts the live state matches what the change assumes — each live leg's aggregator and its exact current bound, and each live cap's snapshot ratio, timestamp and growth against the reviewed values — so a source or cap that has already moved fails the run instead of being rebuilt from something unreviewed.

Every run then replays the 7-call batch on an OP fork as the Owner Safe, verifies the post-state, and rolls back (asserting the rollback). Pranking as the Safe bypasses the signature threshold but not the configurator's role check, so this also confirms the Safe holds role 400. The recorded broadcast list stays exactly the 8 `CREATE`s. Pattern and the `vm.snapshotState`/`vm.revertToState` idiom follow the ether.fi launch pipeline in the `aave-v4` repo (`scripts/etherfi/launch.sh` stage 2, `tests/helpers/spoke/MathHelpers.sol`).

## Run order

```sh
# 1. DONE - deploys the 8 contracts
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RelaxLendStalenessBounds.s.sol:RelaxLendStalenessBounds \
  --rpc-url $OPTIMISM_RPC --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv

# 2. QUEUED at nonce 11 - Lend Owner Safe (0x082B…E844, role 400 on SpokeConfigurator 0xFEe9E8cC…9f8b)
#    output/3CP-644-RelaxLendStaleness-10.json is emitted in the 3CP-Secure schema (identical shape
#    to queued/616/optimism-repoint-price-adapters.json), so it copies straight to
#    queued/644/optimism.json with no reshaping.
```

Only the JSON from a `--broadcast` run is submittable — a dry run deploys into a simulated EVM and its addresses depend on the deployer's nonce.

There is no unsafe window between the steps: step 1 only deploys, the live sources keep serving until the Safe batch executes, and the batch lands all 7 repoints atomically. The batch order (8, 11, 10, 9, 12, 17, 3) is not load-bearing.

## Not touched

The ETH, BTC, USDC, USDT and frxUSD legs; every Veda accountant rate leg (2d); the Midas NAV proxies (7d); and the three OracleSink stock feeds (iwSPYx, iwQQQx, iwTBLLx, 3d).

## After execution

1. Assert the post-state with the same verifier the rehearsal uses. It checks properties rather than addresses and returns the number of reserves checked. Run before the batch executes it fails with `ETHFI: base leg bound is not the relaxed value`, which is expected.

```sh
source .env && FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/RelaxLendStalenessBounds.s.sol:RelaxLendStalenessBounds \
  --sig 'verifyLive()' --rpc-url $OPTIMISM_RPC -v
```

2. Fold the addresses from `output/RelaxedStalenessFeedsOP.json` into `deployments/mainnet/10/summer-lend-feeds.json`. That manifest is already partly stale — its `BTC` entry (`0xd8503124…`) does not appear anywhere in the live source graph.

3. Re-run the whole-market staleness report to confirm nothing else moved:

```sh
source .env && forge script \
  scripts/lend/ReportLendOracleStaleness.s.sol:ReportLendOracleStaleness \
  --rpc-url $OPTIMISM_RPC -v
```

## Rollback

The replaced sources stay deployed and untouched — this batch only moves a pointer. Reverting is the same 7 calls with the "Replaces" column as the third argument.
