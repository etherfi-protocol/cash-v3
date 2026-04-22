# Fund Recovery Module — 3CP Runbook

Operational guide for deploying, wiring, and sanity-checking the Fund Recovery Module across Optimism (source) and 6 destination chains.

## Roles

| Role | Address |
|---|---|
| Operating safe | `0xA6cf33124cb342D1c604cAC87986B965F428AAC4` |
| Deployer (EOA) | `PRIVATE_KEY` env — any funded deployer |

## Chain Matrix

See `lz-config.json` for the authoritative EIDs + LZ v2 endpoint addresses. Source = Optimism (EID `30111`). Destinations: Ethereum, Arbitrum, Base, Linea, Polygon, Avalanche.

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
- `RECOVERY_MODULE_OP` — proxy address

Script prints the `EtherFiDataProvider.configureModules([module],[true])` calldata; this is the FIRST signing bundle for the operating safe on OP (see §5.1).

### 2. Deploy `TopUpDispatcher` on each of the 6 dest chains

For each chain, with its LZ endpoint:

```bash
LZ_ENDPOINT=$(jq -r '.<chain>.endpoint' scripts/recovery/lz-config.json) \
PRIVATE_KEY=$DEPLOYER_PK \
forge script scripts/recovery/DeployTopUpDispatcher.s.sol \
    --rpc-url $<CHAIN>_RPC --broadcast -vvv
```

Record each proxy address as `DISPATCHER_<CHAIN>`.

### 3. Deploy `TopUpV2` impl + emit beacon-upgrade calldata on each dest chain

Requires the dispatcher address from step 2.

```bash
TOPUP_DISPATCHER=$DISPATCHER_<CHAIN> \
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
forge script scripts/recovery/ConfigureLzPeers.s.sol -vvv
```

Prints 12 `setPeer` calldatas (6 for OP module + 6 for dispatchers) that the operating safe will 3CP-sign (§5.3).

Addresses in `ConfigureLzPeers.s.sol` are `address constant` fields at the top of the contract — fill them in and re-compile before running (`forge build && forge script scripts/recovery/ConfigureLzPeers.s.sol -vvv`). The script `require`s that every address is non-zero.

### 5.0 Post-deploy verification (runs before any 3CP signing)

`VerifyRecoveryDeployment.s.sol` recomputes each impl's CREATE3-predicted address from its salt (`keccak256("Recovery.<Contract>Impl.v1")`) and asserts the EIP-1967 slot matches. It also checks the proxy is initialized, the owner is the operating safe, and — on OP — the timelock is 3 days; — on dest chains — `SOURCE_EID == 30111`.

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

## 5. Operating-Safe Signing Bundles

Exactly **14 signatures** total across 7 chains:

### 5.1 On Optimism — 1 tx

| # | Target | Call |
|---|---|---|
| 1 | `EtherFiDataProvider` | `configureModules([RecoveryModule], [true])` |

### 5.2 On each dest chain (Ethereum, Arbitrum, Base, Linea, Polygon, Avalanche) — 2 tx per chain

| # | Target | Call |
|---|---|---|
| 1 | `BeaconFactory` | `upgradeBeaconImplementation(TopUpV2 impl)` |
| 2 | `TopUpDispatcher` | `setPeer(30111, RecoveryModuleOnOp)` |

### 5.3 Back on Optimism — 1 tx (bundle of 6)

| # | Target | Call |
|---|---|---|
| 1 | `RecoveryModule` | `setPeer(eid_i, dispatcher_i)` × 6 |

## 6. Smoke Test

Pick one per-user TopUp on a single dest chain with a small stuck ERC20 balance (ideally < $50). With a 2/2 owner-signed `requestRecovery` digest:

```text
1. owner signs `requestRecovery(safe, token, amount, recipient, destEid, signers, sigs)` on OP
2. wait 3 days
3. any EOA calls `executeRecovery{value: fee}(safe, id, lzOptions)` on OP
   - fee quoted by off-chain `endpoint.quote(...)` OR by `RecoveryModule.quoteExecute(...)`
4. observe `RecoveryDispatched` on the dest-chain TopUpDispatcher
5. confirm ERC20 balance at recipient
```

## 7. Rollback / Emergency Controls

| Scenario | Response |
|---|---|
| Need to halt all new recovery requests + executes on OP | Operating safe calls `pause()` on `RecoveryModule` |
| Need to halt sends to a specific dest chain | Operating safe calls `setPeer(eid, bytes32(0))` on `RecoveryModule` |
| Need to roll back the beacon upgrade on a dest chain | Operating safe calls `upgradeBeaconImplementation(previousImpl)` on `BeaconFactory` |
| A user owner-set wants to abort a pending request | Safe owners sign `cancelRecovery(safe, id, signers, sigs)` — works even while module is paused |

## 8. Verification Checklist Pre-Broadcast

- [ ] Every endpoint address in `lz-config.json` matches https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
- [ ] `VerifyRecoveryDeployment.s.sol` exits 0 on every chain (see §5.0)
- [ ] Implementation addresses recomputed independently: `CREATE3.predictDeterministicAddress(keccak256("Recovery.<Contract>Impl.v1"), 0x4e59b44847b379578588920cA78FbF26c0B4956C)`
- [ ] `RecoveryModule.owner()` == operating safe on OP
- [ ] `TopUpDispatcher.owner()` == operating safe on each dest chain
- [ ] `TopUpDispatcher.SOURCE_EID()` == `30111` on each dest chain
- [ ] Beacon factory on each dest chain matches the address in `deployments/<env>/<chainId>/deployments.json`
- [ ] `TopUpV2.DISPATCHER()` (on each chain) == the corresponding `TopUpDispatcher` proxy
- [ ] `forge inspect TopUp storage-layout` and `forge inspect TopUpV2 storage-layout` diff is empty (no storage fields added)
- [ ] All 12 `setPeer` calldatas recomputed independently by the 3CP reviewer
