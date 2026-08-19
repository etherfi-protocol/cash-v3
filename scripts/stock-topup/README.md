# SPYx topup rail (Ethereum → Optimism)

Topup direction of the stock rails. A user sends raw **SPYx** (`0x90A2…dD48`, Backed's
rebasing stock token) to their TopUp on Ethereum; `TopUpFactory.bridge()` delegatecalls
`StockOFTBridgeAdapter`, which deposits the SPYx into the **wSPYx** ERC-4626 wrapper
(`0xE7E5…B540`) and OFT-sends the shares through Backed's wSPYx OFTAdapter
(`0xB3b3…7318`) to the **TopUpDest on Optimism**, where they land as **iwSPYx**
(`0xc1e6…8D7c`) — the asset already listed as cash collateral by 3CP 622.

Withdraw direction (OP → Ethereum, unwrap to SPYx) is `scripts/stock-withdraw/`.

## What gets deployed / configured

| | |
|---|---|
| `StockOFTBridgeAdapter` | Stateless, unowned, CREATE3 via the EtherFiDeployer. Env-prefixed salt, so dev and prod land at different addresses. Recorded in `deployments/{ENV}/1/deployments.json`. |
| `TopUpFactory.setTokenConfig(SPYx, 10, cfg)` | `bridgeAdapter` = the adapter, `recipientOnDestChain` = OP `TopUpDest`, `maxSlippageInBps` = 100, `additionalData` = `(wSPYx OFTAdapter, 30111, 300_000)`. `onlyRoleRegistryOwner` — the prod operating Safe (`0xA6cf…AAC4`), the deployer EOA on dev. |

Two parameters are load-bearing and both are documented in `StockTopupConfig.sol`:

- **`lzReceiveGas = 300_000`** — the Backed OFTs have **no enforced SEND options**, so an
  empty-options send reverts `Executor_NoOptions` at quote time. Value carried over from the
  withdraw direction, where the mainnet OFTAdapter credit measured ~194k and the live tx
  burned 210k end to end.
- **`maxSlippageInBps = 100`** — dust absorption, not price slippage. The lock/mint OFT takes
  no fee; the only loss is shared-decimals truncation (≤1e12 wei of 18-decimal wSPYx). **At
  0 bps the route cannot even be quoted** — the dust trips `SlippageExceeded` inside
  `quoteSend`.

## Run order

```sh
# 1. Deploy the adapter (registered EtherFiDeployer deployer)
source .env && ENV=mainnet forge script scripts/stock-topup/DeployStockOFTBridgeAdapter.s.sol \
  --rpc-url $MAINNET_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv

# 2. Wire SPYx on the TopUpFactory
#    prod: writes output/SetSpyxTopupConfigEthereum-1.json for the operating Safe
ENV=mainnet forge script scripts/stock-topup/SetSpyxTopupConfigEthereum.s.sol --rpc-url $MAINNET_RPC
#    dev: broadcasts directly (deployer EOA owns the dev RoleRegistry)
ENV=dev PRIVATE_KEY=0x... forge script scripts/stock-topup/SetSpyxTopupConfigEthereum.s.sol \
  --rpc-url $MAINNET_RPC --broadcast

# 3. Verify against the live chain (prod: after the Safe executes the bundle)
ENV=mainnet forge script scripts/stock-topup/VerifyStockTopup.s.sol --rpc-url $MAINNET_RPC
```

Step 2 fork-simulates its own bundle before the JSON is trusted: it asserts every field of the
stored config and then funds the factory with SPYx and executes a **real wrap + OFT send**
through the live adapter, so an lzReceive-gas or slippage value the executor rejects fails
here rather than on a user's topup.

## Not covered here (Optimism side)

`TopUpDest` is token-agnostic — it takes no per-token config, so nothing must be deployed or
wired on OP for the bridged iwSPYx to be creditable by `topUpUserSafe`. What still has to
happen off-chain: the topup backend must recognise SPYx (Ethereum) → iwSPYx (OP) as a
supported pair, and the bridger keeper must call `TopUpFactory.bridge(SPYx, amount, 10)` with
the quoted native fee.
