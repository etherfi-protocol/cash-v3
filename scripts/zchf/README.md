# ZCHF prod collateral rollout (Summer Lend)

> **Status 2026-09-23:** steps 1–2 (relay source + subscription, sink window) are EXECUTED
> (`output/ConfigureZchfRelayEthereum3CP-1.json`, `output/ConfigureZchfSinkOP3CP-10.json`) and the
> sink holds a ZCHF price. The remaining steps (feed, Summer Lend listing, cash side) are now part of the
> combined ZCHF + USDT0 + PAXGy rollout: see [`scripts/zchf-usdt0-paxgy/README.md`](../zchf-usdt0-paxgy/README.md).

Lists **ZCHF** (Frankencoin, CHF stablecoin, native on Optimism at `0xD4dD…5553`) as collateral on
the prod Summer Lend instance, priced the way PAXG was priced by 3CPs 621/622: the mainnet Chainlink
**CHF / USD** aggregator (`0x449d…B13A`) relayed PriceRelay (ETH) → OracleSink (OP) and read by an
immutable `OracleSinkPriceFeed`. No OFT leg (nothing is bridged) and no cash-side wiring
(PriceProviderV2 / DebtManager / LendGateway) — this rollout is the oracle rails plus the lend
reserve. The reserve listing itself is generated in **aave-v4** (`scripts/etherfi/zchf`), because
after the timelock migration only the EtherFiTimelock holds the configurator roles.

## Parameters

| | value | where |
|---|---|---|
| relay source | Chainlink CHF / USD, 8 dec, **26h** bound, Int256, not stable | `ConfigureZchfRelayEthereum3CP` |
| sink window | **7 days** (fixed sink config) | `ConfigureZchfSinkOP3CP` |
| Aave feed | `OracleSinkPriceFeed`, 8 dec, **7-day** relay bound (OP practice), no USD snap, "ZCHF / USD" | `DeployZchfProdFeed` |
| feed address | `0x7445E49137F073B836eB93Fd2929820d730b948C` (CREATE3, salt `ZchfUsdFeed`) | pinned in aave-v4 `AaveV4EtherfiCashAssets.ZCHF_ORACLE` |
| reserve | collateral-only, CF 85% / max bonus 7.5% / liq fee 10%, add cap 1,000,000 — **PROPOSED** | aave-v4 `AaveV4EtherfiCashCollateral`, `AaveV4EtherfiCashCaps` |

Price key everywhere on the rails is **mainnet ZCHF** `0xB58E61C3098d85632Df34EecfB899A1Ed80921cB`
(the relay ships mainnet token addresses); the Summer Lend underlying is the OP token.

## Run order

```sh
# 1. Operating Safe (0xA6cf…AAC4, ETH): relay source + subscription
forge script scripts/zchf/ConfigureZchfRelayEthereum3CP.s.sol --rpc-url $MAINNET_RPC

# 2. Operating Safe (0xA6cf…AAC4, OP): sink window — independent of 1, can go out together
forge script scripts/zchf/ConfigureZchfSinkOP3CP.s.sol --rpc-url $OPTIMISM_RPC

# 3. wait for the relay keeper (full poke every 2h) — the sink must hold a ZCHF price

# 4. EOA (registered EtherFiDeployer deployer): immutable feed on OP + manifest update
source .env && ENV=mainnet forge script scripts/zchf/DeployZchfProdFeed.s.sol:DeployZchfProdFeed \
  --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
forge script scripts/zchf/DeployZchfProdFeed.s.sol:DeployZchfProdFeed --sig 'verify()' --rpc-url $OPTIMISM_RPC

# 5. aave-v4: Timelock Safe schedules, 24h, Timelock Safe executes (see that repo)
forge script scripts/etherfi/zchf/EtherfiCashZchfCollateral.s.sol --sig 'configure()' --rpc-url optimism
```

Every generator fork-simulates its bundle and asserts the post-state before the JSON is trusted.
`DeployZchfProdFeed --sig 'rehearse()'` proves the feed prices on a fork before anything is broadcast
(it seeds the sink when the relay has not delivered yet).

**Ordering that matters:** the feed may be deployed before the relay delivers (immutable, address
final), but the aave-v4 listing must not be **executed** until `verify()` is green —
`AaveOracle.setReserveSource` reads `latestAnswer()` and the whole timelock operation reverts on a
feed that cannot price.
