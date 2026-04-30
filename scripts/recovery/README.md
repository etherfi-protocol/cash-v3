# Fund Recovery Module — 3CP Runbook

Operational guide for deploying, wiring, and sanity-checking the Fund Recovery Module across Optimism (source) and 5 destination chains.

## Roles

| Role | Address |
|---|---|
| Operating safe | `0xA6cf33124cb342D1c604cAC87986B965F428AAC4` |
| Deployer (EOA) | `PRIVATE_KEY` env — any funded deployer |

## Chain Matrix

See `lz-config.json` for the authoritative EIDs + LZ v2 endpoint addresses. Source = Optimism (EID `30111`). Destinations: Ethereum, Arbitrum, Base, BNB, HyperEVM.

## Deployment Sequence

Order matters: addresses from steps 1–3 feed the peer-wiring calldata in step 4.

### 1. Deploy `AssetRecoveryModule` on Optimism

```bash
LZ_ENDPOINT=$(jq -r '.optimism.endpoint' scripts/recovery/lz-config.json) \
PRIVATE_KEY=$DEPLOYER_PK \
forge script scripts/recovery/DeployAssetRecoveryModule.s.sol \
    --rpc-url $OP_RPC --broadcast -vvv
```

Record:
- `RECOVERY_MODULE_OP` — module address (non-upgradable; deployed directly via CREATE3)

Script prints the `EtherFiDataProvider.configureModules([module],[true])` calldata; this is the FIRST signing bundle for the operating safe on OP (see §5.1).

### 2. Deploy `AssetRecoveryDispatcher` on each of the 5 dest chains

For each chain, with its LZ endpoint and the local `TopUpFactory` proxy address:

```bash
LZ_ENDPOINT=$(jq -r '.<chain>.endpoint' scripts/recovery/lz-config.json) \
TOPUP_FACTORY=$<CHAIN>_TOPUP_FACTORY \
PRIVATE_KEY=$DEPLOYER_PK \
forge script scripts/recovery/DeployAssetRecoveryDispatcher.s.sol \
    --rpc-url $<CHAIN>_RPC --broadcast -vvv
```

`TOPUP_FACTORY` is consumed by the dispatcher's lazy-deploy branch: if the user's TopUp proxy isn't on this chain yet (e.g. they only ever sent an unsupported token here, so the topup batch path never ran), the dispatcher will call `TopUpFactory.deployTopUpContract(salt)` itself before sweeping. Get it from the chain's `cash-v3` deployments file.

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

Prints 10 `setPeer` calldatas (5 for OP module + 5 for dispatchers) that the operating safe will 3CP-sign (§5.3).

Addresses in `ConfigureLzPeers.s.sol` are `address constant` fields at the top of the contract — fill them in and re-compile before running (`forge build && forge script scripts/recovery/ConfigureLzPeers.s.sol -vvv`). The script `require`s that every address is non-zero.

### 4.5. Grant pauser roles on dest chains

Without these grants, `pause()` / `unpause()` on `AssetRecoveryDispatcher` and `TopUpV2.executeRecovery`'s `whenNotPaused` ancestor will revert. **Run before going live on each chain.**

The operating safe `0xA6cf33124cb342D1c604cAC87986B965F428AAC4` is already `owner()` of `RoleRegistry` on every dest chain (verified on-chain). On Optimism the operating safe already holds both PAUSER and UNPAUSER (verified on-chain) — no action needed there.

Per dest chain, the operating safe must call `RoleRegistry.grantRole(role, 0xA6cf33124cb342D1c604cAC87986B965F428AAC4)` for both:

- `PAUSER` = `0x539440820030c4994db4e31b6b800deafd503688728f932addfe7a410515c14c` (= `keccak256("PAUSER")`)
- `UNPAUSER` = `0x82b32d9ab5100db08aeb9a0e08b422d14851ec118736590462bf9c085a6e9448` (= `keccak256("UNPAUSER")`)

`RoleRegistry` address per chain:

- **Ethereum (1)** — `RoleRegistry = 0x55963de88267Aa3D1D995c359e8068D0Df34BEBb`
  - `grantRole(PAUSER, 0xA6cf...AAC4)`
  - `grantRole(UNPAUSER, 0xA6cf...AAC4)`
- **Arbitrum (42161)** — `RoleRegistry = 0x55963de88267Aa3D1D995c359e8068D0Df34BEBb`
  - `grantRole(PAUSER, 0xA6cf...AAC4)`
  - `grantRole(UNPAUSER, 0xA6cf...AAC4)`
- **Base (8453)** — `RoleRegistry = 0x55963de88267Aa3D1D995c359e8068D0Df34BEBb`
  - `grantRole(PAUSER, 0xA6cf...AAC4)`
  - `grantRole(UNPAUSER, 0xA6cf...AAC4)`
- **BNB (56)** — `RoleRegistry = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B`
  - `grantRole(PAUSER, 0xA6cf...AAC4)`
  - `grantRole(UNPAUSER, 0xA6cf...AAC4)`
- **HyperEVM (999)** — `RoleRegistry = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B`
  - `grantRole(PAUSER, 0xA6cf...AAC4)`
  - `grantRole(UNPAUSER, 0xA6cf...AAC4)`

Total: 10 grants (2 per chain × 5 chains). Bundle each chain's pair into a single Safe transaction.

### 5.0 Post-deploy verification (runs before any 3CP signing)

`VerifyRecoveryDeployment.s.sol` recomputes each contract's CREATE3-predicted address from its salt and asserts the on-chain code lives there. For the (non-upgradable) `AssetRecoveryModule` on OP it asserts the address itself matches the predicted CREATE3 address. For the UUPS singletons (`AssetRecoveryDispatcher`, `TopUpV2` impl) it asserts the EIP-1967 impl slot matches the predicted impl. In every case it also checks the owner is the operating safe and — on dest chains — `SOURCE_EID == 30111`.

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

Exactly **12 signatures** total across 6 chains:

### 5.1 On Optimism — 1 tx

| # | Target | Call |
|---|---|---|
| 1 | `EtherFiDataProvider` | `configureModules([AssetRecoveryModule], [true])` |

### 5.2 On each dest chain (Ethereum, Arbitrum, Base, BNB, HyperEVM) — 2 tx per chain (10 total)

| # | Target | Call |
|---|---|---|
| 1 | `BeaconFactory` | `upgradeBeaconImplementation(TopUpV2 impl)` |
| 2 | `AssetRecoveryDispatcher` | `setPeer(30111, AssetRecoveryModuleOnOp)` |

### 5.3 Back on Optimism — 1 tx (bundle of 5)

| # | Target | Call |
|---|---|---|
| 1 | `AssetRecoveryModule` | `setPeer(eid_i, dispatcher_i)` × 5 |

## 6. Smoke Test

Pick one per-user TopUp on a single dest chain with a small stuck ERC20 balance (ideally < $50). Single-call flow:

```text
1. owner quotes the LZ native fee off-chain (LZ SDK / endpoint `quote()`)
2. owners sign `recover(safe, token, recipient, safeSalt, destEid, lzOptions, signers, sigs)` on OP —
   the user-signed digest does NOT bind an amount; the destination sweeps the full balance.
3. submitter calls `recover{value: nativeFee}(...)` — LZ message ships in this same tx
4. observe `RecoverySent` on OP and `RecoveryDispatched` on the dest-chain AssetRecoveryDispatcher
5. confirm ERC20 balance at recipient — equals whatever the destination TopUp held at LZ delivery
```

**Empty-balance behavior.** `TopUpV2.executeRecovery` reverts with `NoBalanceToRecover` if the destination TopUp's `balanceOf(token)` is zero at LZ delivery. The LZ packet stays retryable, so once funds actually arrive on the destination chain the executor can replay the message. Any dust that lands between submit on OP and LZ delivery is swept along with the rest — there is no longer an exact-amount check to brick the call.

## 7. Rollback / Emergency Controls

| Scenario | Response |
|---|---|
| Need to halt all new recoveries on OP | Operating safe calls `pause()` on `AssetRecoveryModule` |
| Need to halt sends to a specific dest chain | Operating safe calls `setPeer(eid, bytes32(0))` on `AssetRecoveryModule` |
| Need to halt all incoming recoveries on a dest chain | Operating safe calls `pause()` on the local `AssetRecoveryDispatcher` |
| Need to roll back the beacon upgrade on a dest chain | Operating safe calls `upgradeBeaconImplementation(previousImpl)` on `BeaconFactory` |

## 8. Verification Checklist Pre-Broadcast

- [ ] Every endpoint address in `lz-config.json` matches https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
- [ ] `VerifyRecoveryDeployment.s.sol` exits 0 on every chain (see §5.0)
- [ ] CREATE3-predicted addresses recomputed independently using Nick's factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` and the salts in `RecoveryDeployConfig.sol` (`SALT_RECOVERY_MODULE` for the OP module, `SALT_RECOVERY_DISPATCHER_IMPL` and `SALT_TOPUP_V2_IMPL` for the UUPS impls)
- [ ] `AssetRecoveryModule.owner()` == operating safe on OP
- [ ] `AssetRecoveryDispatcher.owner()` == operating safe on each dest chain
- [ ] `AssetRecoveryDispatcher.SOURCE_EID()` == `30111` on each dest chain
- [ ] `AssetRecoveryDispatcher.TOPUP_FACTORY()` == local TopUpFactory proxy on each dest chain (verifies the lazy-deploy branch is wired to the right factory)
- [ ] Beacon factory on each dest chain matches the address in `deployments/<env>/<chainId>/deployments.json`
- [ ] `TopUpV2.DISPATCHER()` (on each chain) == the corresponding `AssetRecoveryDispatcher` proxy
- [ ] `forge inspect TopUp storage-layout` and `forge inspect TopUpV2 storage-layout` diff is empty (no storage fields added)
- [ ] All 10 `setPeer` calldatas recomputed independently by the 3CP reviewer
