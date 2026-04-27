# Fund Recovery Module — 3CP Runbook

Operational guide for deploying, wiring, and sanity-checking the Fund Recovery Module across Optimism (source) and 7 destination chains.

## Roles

| Role | Address |
|---|---|
| Operating safe | `0xA6cf33124cb342D1c604cAC87986B965F428AAC4` |
| Deployer (EOA) | `PRIVATE_KEY` env — any funded deployer |

## Chain Matrix

See `lz-config.json` for the authoritative EIDs + LZ v2 endpoint addresses. Source = Optimism (EID `30111`). Destinations: Ethereum, Arbitrum, Base, Linea, Polygon, Avalanche, BNB.

## Deployment Sequence

Order matters: addresses from steps 1–3 feed the peer-wiring calldata in step 4.

### 1. Deploy `RecoveryModule` on Optimism

```bash
LZ_ENDPOINT=$(jq -r '.optimism.endpoint' scripts/recovery/lz-config.json) \
PRIVATE_KEY=$DEPLOYER_PK \
forge script scripts/recovery/DeployRecoveryModule.s.sol \
    --rpc-url $OP_RPC --broadcast -vvv
```

Record:
- `RECOVERY_MODULE_OP` — module address (non-upgradable; deployed directly via CREATE3)

Script prints the `EtherFiDataProvider.configureModules([module],[true])` calldata; this is the FIRST signing bundle for the operating safe on OP (see §5.1).

### 2. Deploy `RecoveryDispatcher` on each of the 7 dest chains

For each chain, with its LZ endpoint:

```bash
LZ_ENDPOINT=$(jq -r '.<chain>.endpoint' scripts/recovery/lz-config.json) \
PRIVATE_KEY=$DEPLOYER_PK \
forge script scripts/recovery/DeployRecoveryDispatcher.s.sol \
    --rpc-url $<CHAIN>_RPC --broadcast -vvv
```

Record each proxy address as `DISPATCHER_<CHAIN>`.

### 3. Deploy `TopUpV2` impl + emit beacon-upgrade calldata on each dest chain

Requires the dispatcher address from step 2.

```bash
RECOVERY_DISPATCHER=$DISPATCHER_<CHAIN> \
PRIVATE_KEY=$DEPLOYER_PK \
forge script scripts/recovery/UpgradeTopUpImpl.s.sol \
    --rpc-url $<CHAIN>_RPC --broadcast -vvv
```

Record each `TopUpV2` impl address. Script prints the `BeaconFactory.upgradeBeaconImplementation(impl)` calldata — this is the operating safe's SECOND signing bundle per chain (§5.2).

### 4. Generate peer-wiring calldata

```bash
RECOVERY_MODULE_OP=$MODULE_ADDR \
DISPATCHER_ETH=$ETH_DISP DISPATCHER_ARB=$ARB_DISP \
DISPATCHER_BASE=$BASE_DISP DISPATCHER_LINEA=$LINEA_DISP \
DISPATCHER_POLYGON=$POLY_DISP DISPATCHER_AVAX=$AVAX_DISP \
DISPATCHER_BNB=$BNB_DISP \
forge script scripts/recovery/ConfigureLzPeers.s.sol -vvv
```

Prints 14 `setPeer` calldatas (7 for OP module + 7 for dispatchers) that the operating safe will 3CP-sign (§5.3).

Addresses in `ConfigureLzPeers.s.sol` are `address constant` fields at the top of the contract — fill them in and re-compile before running (`forge build && forge script scripts/recovery/ConfigureLzPeers.s.sol -vvv`). The script `require`s that every address is non-zero.

### 5.0 Post-deploy verification (runs before any 3CP signing)

`VerifyRecoveryDeployment.s.sol` recomputes each contract's CREATE3-predicted address from its salt and asserts the on-chain code lives there. For the (non-upgradable) `RecoveryModule` on OP it asserts the address itself matches the predicted CREATE3 address. For the UUPS singletons (`RecoveryDispatcher`, `TopUpV2` impl) it asserts the EIP-1967 impl slot matches the predicted impl. In every case it also checks the owner is the operating safe and — on dest chains — `SOURCE_EID == 30111`.

On Optimism:
```bash
RECOVERY_MODULE_OP=$MODULE_ADDR \
forge script scripts/recovery/VerifyRecoveryDeployment.s.sol --rpc-url $OP_RPC
```

On each dest chain (after deploys in steps 2–3):
```bash
DISPATCHER=$DISPATCHER_<CHAIN> TOPUP_V2_IMPL=$TOPUPV2_<CHAIN> BEACON=$BEACON_<CHAIN> \
forge script scripts/recovery/VerifyRecoveryDeployment.s.sol --rpc-url $<CHAIN>_RPC
```

Any failed `require()` reverts the script with a nonzero exit code. **Do not proceed to signing unless verify passes on every chain.**

After §5.1 has been signed (module whitelisted on `EtherFiDataProvider`), re-run the OP verifier with `EXPECT_WHITELISTED=1` to assert the whitelist landed:

```bash
EXPECT_WHITELISTED=1 RECOVERY_MODULE_OP=$MODULE_ADDR LZ_ENDPOINT=$LZ_OP \
ETHER_FI_DATA_PROVIDER=$DP_OP \
forge script scripts/recovery/VerifyRecoveryDeployment.s.sol --rpc-url $OP_RPC
```

## 5. Operating-Safe Signing Bundles

Exactly **16 signatures** total across 8 chains:

### 5.1 On Optimism — 1 tx

| # | Target | Call |
|---|---|---|
| 1 | `EtherFiDataProvider` | `configureModules([RecoveryModule], [true])` |

### 5.2 On each dest chain (Ethereum, Arbitrum, Base, Linea, Polygon, Avalanche, BNB) — 2 tx per chain (14 total)

| # | Target | Call |
|---|---|---|
| 1 | `BeaconFactory` | `upgradeBeaconImplementation(TopUpV2 impl)` |
| 2 | `RecoveryDispatcher` | `setPeer(30111, RecoveryModuleOnOp)` |

### 5.3 Back on Optimism — 1 tx (bundle of 7)

| # | Target | Call |
|---|---|---|
| 1 | `RecoveryModule` | `setPeer(eid_i, dispatcher_i)` × 7 |

## 6. Smoke Test

Pick one per-user TopUp on a single dest chain with a small stuck ERC20 balance (ideally < $50). Single-call flow:

```text
1. owner queries `RecoveryModule.quote(safe, token, amount, recipient, destEid, lzOptions)`
2. owners sign `recover(safe, token, amount, recipient, destEid, lzOptions, signers, sigs)` on OP
3. submitter calls `recover{value: nativeFee}(...)` — LZ message ships in this same tx
4. observe `RecoverySent` on OP and `RecoveryDispatched` on the dest-chain RecoveryDispatcher
5. confirm ERC20 balance at recipient
```

**Dust-brick caveat.** `TopUpV2.executeRecovery` enforces `amount == balanceOf(token, address(this))`. If any inbound transfer hits the destination TopUp between submit on OP and LZ delivery, the call reverts (`AmountMustEqualBalance`) and the LZ packet stays stuck. Ops then needs to clear the dust (or sweep via a follow-up recovery sized to the new balance) before the original packet can be retried by the LZ executor.

## 7. Rollback / Emergency Controls

| Scenario | Response |
|---|---|
| Need to halt all new recoveries on OP | Operating safe calls `pause()` on `RecoveryModule` |
| Need to halt sends to a specific dest chain | Operating safe calls `setPeer(eid, bytes32(0))` on `RecoveryModule` |
| Need to halt all incoming recoveries on a dest chain | Operating safe calls `pause()` on the local `RecoveryDispatcher` |
| Need to roll back the beacon upgrade on a dest chain | Operating safe calls `upgradeBeaconImplementation(previousImpl)` on `BeaconFactory` |

## 8. Verification Checklist Pre-Broadcast

- [ ] Every endpoint address in `lz-config.json` matches https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
- [ ] `VerifyRecoveryDeployment.s.sol` exits 0 on every chain (see §5.0)
- [ ] CREATE3-predicted addresses recomputed independently using Nick's factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` and the salts in `RecoveryDeployConfig.sol` (`SALT_RECOVERY_MODULE` for the OP module, `SALT_RECOVERY_DISPATCHER_IMPL` and `SALT_TOPUP_V2_IMPL` for the UUPS impls)
- [ ] `RecoveryModule.owner()` == operating safe on OP
- [ ] `RecoveryDispatcher.owner()` == operating safe on each dest chain
- [ ] `RecoveryDispatcher.SOURCE_EID()` == `30111` on each dest chain
- [ ] Beacon factory on each dest chain matches the address in `deployments/<env>/<chainId>/deployments.json`
- [ ] `TopUpV2.DISPATCHER()` (on each chain) == the corresponding `RecoveryDispatcher` proxy
- [ ] `forge inspect TopUp storage-layout` and `forge inspect TopUpV2 storage-layout` diff is empty (no storage fields added)
- [ ] All 14 `setPeer` calldatas recomputed independently by the 3CP reviewer
