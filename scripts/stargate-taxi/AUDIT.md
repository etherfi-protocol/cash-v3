# Stargate instance audit

Audit date: 2026-08-24

## Scroll StargateModule

The Scroll module is active and must move to taxi mode.

- Module: `0xC1ab383b81fD81803a54c4d50A7b7d4A31a317b4`
- The Scroll explorer returned 1,000 `BridgeWithStargate` events. The API limits one response to 1,000 events.
- A second query after block `30,000,000` also reached the 1,000 event limit.
- The module is still both whitelisted and configured as a default module.
- The events use Ethereum EID `30101` and Base EID `30184`.
- The events use Scroll USDC and weETH.
- `getAssetConfig(Scroll USDC)` returns the Stargate USDC pool `0x3Fc69CC4A842838bCDC9499178740226062b14E4` with `isOFT == false`.
- `getAssetConfig(Scroll weETH)` returns the weETH contract with `isOFT == true`.

The route test now includes Scroll USDC to Ethereum and Scroll USDC to Base. The weETH path already uses the OFT send command.

## Ethereum StargateAdapter

The Ethereum adapter has historical use but no current route points to it.

- Adapter: `0x9895784c9e5ec67480f92238220D0400316ff84a`
- TopUpFactory: `0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF`
- The factory emitted 101 historical `BridgeViaStargate` events for USDC and WETH.
- The latest event was at `2025-06-27 16:45:59 UTC` in transaction `0xa90f58c6dc2cc953c95e97d5b4e8eedaf871e8cd519d70dd4fc358b9b4a3b092`.
- Current WETH routes use `ScrollERC20BridgeAdapter` for Scroll and `OptimismBridgeAdapter` for Optimism.
- Current USDC routes use `ScrollERC20BridgeAdapter` for Scroll and `CCTPAdapter` for Optimism.
- The current Ethereum top up fixtures contain no Stargate route.

`StargateAdapter` runs through `delegatecall`. Its events therefore use the TopUpFactory address instead of the adapter address.

The Ethereum adapter is excluded from the taxi deployment.

## Deployment scope

The contract deployment must include these live instances:

- Optimism `StargateModule`: `0xee77DEB6991f5d5CcAE5a327debA32d292E85c1c`
- Scroll `StargateModule`: `0xC1ab383b81fD81803a54c4d50A7b7d4A31a317b4`
- Optimism Reap `SettlementDispatcherV2`: `0x9623e86Df854FF3b48F7B4079a516a4F64861Db2`
- Optimism Rain `SettlementDispatcherV2`: `0x50A233C4a0Bb1d7124b0224880037d35767a501C`
- Optimism PIX `SettlementDispatcherV2`: `0x95aaddD43b6edF838ec486E9f9814787212Bf42D`
- Optimism CardOrder `SettlementDispatcherV2`: `0xb14FDfd7D2cfFb6Cc6953C1b80F1B1d12c2F766a`
- Base `StargateAdapter`: `0x51dD76A7081c7b84e410A77968a72EEeE1Caf4C3`

The mainnet deployment registries identify each address above. The Optimism configuration also records the live USDC Stargate pool. The deployed-sanity checks read these module and proxy addresses to verify their live code and configuration. The Base top-up fixture routes WETH through the deployed Stargate adapter to Scroll and Optimism.

The deployment must exclude the unused Ethereum `StargateAdapter`.

## Sources

- [Scroll StargateModule](https://scrollscan.com/address/0xc1ab383b81fd81803a54c4d50a7b7d4a31a317b4)
- [Optimism StargateModule](https://optimistic.etherscan.io/address/0xee77deb6991f5d5ccae5a327deba32d292e85c1c)
- [Optimism Reap dispatcher](https://optimistic.etherscan.io/address/0x9623e86df854ff3b48f7b4079a516a4f64861db2)
- [Optimism Rain dispatcher](https://optimistic.etherscan.io/address/0x50a233c4a0bb1d7124b0224880037d35767a501c)
- [Optimism PIX dispatcher](https://optimistic.etherscan.io/address/0x95aaddd43b6edf838ec486e9f9814787212bf42d)
- [Optimism CardOrder dispatcher](https://optimistic.etherscan.io/address/0xb14fdfd7d2cffb6cc6953c1b80f1b1d12c2f766a)
- [Base StargateAdapter](https://basescan.org/address/0x51dd76a7081c7b84e410a77968a72eeee1caf4c3)
- [Latest historical Ethereum Stargate top up](https://etherscan.io/tx/0xa90f58c6dc2cc953c95e97d5b4e8eedaf871e8cd519d70dd4fc358b9b4a3b092)
- [Optimism deployment registry](../../deployments/mainnet/10/deployments.json)
- [Base deployment registry](../../deployments/mainnet/8453/deployments.json)
- [Base top-up routes](../../deployments/mainnet/fixtures/top-up-fixtures.json)
