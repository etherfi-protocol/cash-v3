# sETHFI top-ups from Arbitrum and Base (3CP-733)

A user sends sETHFI (`0x86B5780b606940Eb59A062aA85a07959518c0161`, same address on every chain) to
their TopUp on Arbitrum or Base. The sETHFI LayerZero teller (`0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b`)
is hub and spoke: the Arbitrum and Base tellers peer only with Ethereum (eid 30101), so the route has two legs.

1. `TopUpFactory.bridge(sETHFI, amount, 10)` on Arbitrum or Base sends through `EtherFiLiquidBridgeAdapter`
   to the **Ethereum TopUpFactory** (`0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF`).
2. `TopUpFactory.bridge(sETHFI, amount, 10)` on Ethereum sends on to the OP `TopUpDest` with the config that
   is already live there.

The config is keyed by chain 10, the final destination, the same way Base USDT is configured today.

## What gets deployed / configured

| | |
|---|---|
| `EtherFiLiquidBridgeAdapter` (Arbitrum) | Stateless, unowned, CREATE3 via the EtherFiDeployer under `Prod.SEthFiTopUp.Arbitrum.EtherFiLiquidBridgeAdapter` → `0x37F49CBc160939c6e8d74d0AD138557965b7CCbE`. Base reuses the live adapter `0x44E95b85CE77E4c7cfc6f866b37553b5Cbcf6D32`. |
| `TopUpFactory.setTokenConfig(sETHFI, 10, cfg)` | `bridgeAdapter` = the chain's liquid adapter, `recipientOnDestChain` = Ethereum TopUpFactory, `maxSlippageInBps` = 50 (matches Ethereum; the adapter ignores it), `additionalData` = `(teller, 30101)`. `onlyAdminTimelock`: scheduled and executed by the operating Safe (`0xA6cf…AAC4`) through the 8h operating timelock (`0x9AEb…7849`). |

## Run order

```sh
# 1. Deploy the Arbitrum adapter (registered EtherFiDeployer deployer), then record it under
#    EtherFiLiquidBridgeAdapter in deployments/mainnet/42161/deployments.json
ENV=mainnet forge script scripts/sethfi-topup/DeploySEthFiTopUpAdapterArbitrum.s.sol \
  --rpc-url $ARBITRUM_RPC --ledger --sender $PROD_DEPLOYER --broadcast --verify

# 2. Generate and fork-simulate the 3CP bundles (no broadcast)
ENV=mainnet forge script scripts/sethfi-topup/SEthFiTopUp3CP.s.sol --rpc-url $ARBITRUM_RPC
ENV=mainnet forge script scripts/sethfi-topup/SEthFiTopUp3CP.s.sol --rpc-url $BASE_RPC
```

Step 2 writes `output/sethfi-topup-<chain>-<nonce>-{schedule,execute}-sethfi-topup-config.json`, then on the
fork: schedules, checks the execute reverts before the delay, warps 8h, executes, asserts every stored config
field, and bridges 1 sETHFI through the live teller as a real bridger. If the Arbitrum adapter is not deployed
yet it is deployed on the fork only; the real deploy must land before signing.

## Not covered here

The top-up service (cash-topup-v3) must list sETHFI for the Arbitrum and Base trackers, and the Ethereum
bridger must forward sETHFI that lands in the Ethereum TopUpFactory itself (leg 2).
