# All-Chains Asset Recovery — Launch Checklist

Single rollout for the 5 remaining destination chains. You sign all commits (`git commit -S`).
**`audit/topup-factory-reinitializer` is OFF-LIMITS** — it owns the Polygon reinitializer and merges
after its own 3CP. Everything below goes on a new integration branch.

## Chains in scope

| Chain     | chainId | LZ EID | Deploy type            | setConfig (DVN)        | Source branch              | Readiness |
|-----------|---------|--------|------------------------|------------------------|----------------------------|-----------|
| Gnosis    | 100     | 30145  | fresh (initialize)     | default — none         | `feat/gnosis-recovery`     | ready |
| Polygon   | 137     | 30109  | **placeholder (reinit)** | default — none       | `feat/polygon-recovery` + **audit** | reinit in audit |
| opBNB     | 204     | 30202  | fresh (initialize)     | **YES** LZ Labs `0x3ebb618b…` | `feat/opbnb-xlayer-recovery` | setConfig unbuilt |
| X-Layer   | 196     | 30274  | fresh (initialize)     | **YES** LZ Labs `0x9c061c9a…` | `feat/opbnb-xlayer-recovery` | setConfig unbuilt |
| Avalanche | 43114   | 30106  | fresh (initialize)     | verify (likely default)| **none**                   | net-new |

## Common constants (same on every chain)

- Operating safe (3CP signer / OApp owner / RR upgrader): `0xA6cf33124cb342D1c604cAC87986B965F428AAC4`
- Deployer (Ledger): `0x8D5AAc…Bb150`
- OP cross-chain module (peer target on OP side): `0x431d271D544aC67fAfFa8a9FfabAabCB14563102`
- Dispatcher (canonical CREATE3, same on every dest chain): `0x418e0af7c750Ba5cbffC5C2a8398591755926A29`
- TopUp factory proxy (canonical CREATE3): `0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF`
- OP source EID: `30111`

---

## Phase 0 — Consolidate branches → `feat/recovery-all-chains`

Cut fresh off `master` (NOT off audit). Re-apply each branch's changes, resolving the shared files:

| File | Action |
|------|--------|
| `scripts/recovery/DeployRecoveryRoleRegistry.s.sol` | take **gnosis** (Ledger `vm.startBroadcast()`); drop opbnb's `PRIVATE_KEY` copy |
| `scripts/recovery/DeployRecoveryTopUpFactory.s.sol` | take **gnosis** (Ledger); drop opbnb's `PRIVATE_KEY` copy |
| `scripts/recovery/DeployAssetRecoveryDispatcher.s.sol`, `DeployTopUpV2Impl.s.sol` | from gnosis; **confirm both are Ledger-compat** (bare `startBroadcast`) |
| `scripts/gnosis-txs/RecoveryDestChain3CP.s.sol` | **union**: TopUpV2 constants + chainid switch for 100/137/204/196/43114. Body identical across branches. For 204/196 add 5th tx = receive setConfig (see Phase 0b) |
| OP-side 3CP | **collapse** `RecoveryOPAddGnosis3CP` + `RecoveryOPAddPolygon3CP` + `RecoveryOPAddChains3CP` into ONE `RecoveryOPAddChains3CP.s.sol`: `setPeer` for 30109/30145/30106/30202/30274 + send setConfig for opBNB/X-Layer. Read module from `deployments.json` (polygon version's pattern) |
| `scripts/recovery/lz-config.json` | union all entries + add `avalanche {43114, 30106, 0x1a44…728c}` |
| `deployments/mainnet/{100,204,196,43114}/deployments.json` | per-chain recovery address blocks (filled in Phase 1) |
| fork tests | `RecoverySourceForkGnosis.t.sol`, `RecoverySourceForkOpBnbXLayer.t.sol`, + new avax fork test |
| **Polygon, do NOT copy** | `src/top-up/TopUpFactory.sol`, `DeployPolygonTopUpFactory.s.sol`, `PolygonPlaceholderUpgradeFork.t.sol` — these stay in `audit`. Polygon enters this branch only as the 137 entry in the two 3CP scripts |

### Phase 0b — Net-new work (not just a merge)

- [x] **opBNB/X-Layer setConfig** (was "blocked on DVN") — built in `scripts/recovery/RecoverySetConfigLib.sol`,
      wired into both 3CPs: OP send-ULN (module) in `RecoveryOPAddChains3CP`, dest receive-ULN (dispatcher)
      in `RecoveryDestChain3CP`. OP send side **proven on a live fork** (`RecoverySetConfigProbe` passes —
      OP→opBNB / OP→X-Layer quotable via the lib's calldata). Receive lib+DVN want the Phase 0.5 dev
      round-trip to confirm delivery. All addresses from LZ metadata, parsed deterministically + checksummed.
- [ ] **Avalanche**: lz-config entry, deployments block, dest-3CP + OP-3CP entries, fork test, and
      **verify the OP↔Avalanche default DVN pathway** (if no default route, it needs setConfig like opBNB).
- [ ] Verify EIDs against LZ docs: Polygon 30109, Gnosis 30145, Avalanche 30106, opBNB 30202, X-Layer 30274.

Then: `git add … && git commit -S` (you), push, open PR.

---

## Phase 0.5 — Dev rehearsal (before ANY prod deploy)

Risk-based, not one-size. Fork tests already cover contract logic; dev proves the parts they can't.

- [ ] **opBNB + X-Layer — LZ round-trip (MUST, gates prod).** Deploy the dev stack on each + apply the
      dev setConfig, then send a real recovery message OP↔chain and confirm delivery. Only proof the
      custom DVN pathway actually works. Depends on Phase 0b (setConfig) being built.
- [ ] **Polygon — dev rehearsal** of the placeholder→`reinitialize` upgrade (novel path). See
      `REHEARSE_POLYGON.md` / `DeployDevPolygon*` scripts.
- [ ] **Gnosis / Avalanche — one confirmatory dev round-trip** (default DVN; low risk).
- [ ] **BE/FE** — cross-chain recovery already shipped (base/arb/bnb/eth/hyperevm). Add the 5 chains to
      the dev config, confirm they list + a dev recovery completes. Config addition, not new wiring.

> Tooling: `deployments/dev/*`, `DeployDevPolygon*` (polygon branch), `REHEARSE_*.md`.

---

## Phase 1 — Deploy infra (deployer Ledger), per FRESH chain (Gnosis, opBNB, X-Layer, Avalanche)

Run in order; each records into `deployments/mainnet/<id>/deployments.json`. Ledger pattern:
```
forge script scripts/recovery/<Script>.s.sol \
  --rpc-url $<CHAIN>_RPC --ledger \
  --mnemonic-derivation-paths "m/44'/60'/0'/0/0" \
  --sender 0x8D5AAc…Bb150 --broadcast --verify
```
1. [ ] `DeployRecoveryRoleRegistry` → record `RoleRegistry`
2. [ ] `DeployRecoveryTopUpFactory` → record `TopUpSourceFactory` (= canonical `0xF4e147…`); beacon = base TopUp impl
3. [ ] `DeployTopUpV2Impl` → **fill `TOPUP_V2_<chain>` constant** in `RecoveryDestChain3CP.s.sol`
4. [ ] `DeployAssetRecoveryDispatcher` → record `AssetRecoveryDispatcher` (= canonical `0x418e…`)

**Polygon** (placeholder): instead of step 2 run **`DeployPolygonTopUpFactory` from the audit branch**
(deploys factory+TopUp impls + prints the `upgradeToAndCall(reinitialize)` 3CP calldata). Still run
steps 3 + 4 (TopUpV2 impl + dispatcher); RR already on-chain.

> Gas on the deployer EOA on each chain. Deploys are independent — parallelizable across chains.

---

## Phase 2 — Operating safe per chain

- [ ] Deploy the operating safe (`0xA6cf33…`) on each chain via the Safe app (needed to execute the 3CPs).
      Independent of Phase 1; can run in parallel.

---

## Phase 3 — Destination 3CP (operating safe), one bundle per chain

`RecoveryDestChain3CP.s.sol` on the chain's RPC → `output/Recovery3CP-dest-<id>.json`. Bundle:
1. `RoleRegistry.grantRole(PAUSER, operatingSafe)`
2. `RoleRegistry.grantRole(UNPAUSER, operatingSafe)`
3. `TopUpSourceFactory.upgradeBeaconImplementation(TopUpV2 impl)`
4. `dispatcher.setPeer(30111, OP module)`
5. *(opBNB/X-Layer only)* receive-ULN `endpoint.setConfig(...)`

- [ ] Gnosis  - [ ] Polygon (+ the reinit `upgradeToAndCall` from audit) - [ ] opBNB - [ ] X-Layer - [ ] Avalanche

> One safeTxHash + one signature per signer **per chain** (MultiSend bundles into a single sig).

---

## Phase 4 — OP-side 3CP (operating safe), ONE batch for all chains

`RecoveryOPAddChains3CP.s.sol` on OP → `output/Recovery3CP-op-<all>.json`. One bundle:
- [ ] `module.setPeer(30109, dispatcher)`  (Polygon)
- [ ] `module.setPeer(30145, dispatcher)`  (Gnosis)
- [ ] `module.setPeer(30106, dispatcher)`  (Avalanche)
- [ ] `module.setPeer(30202, dispatcher)`  (opBNB)
- [ ] `module.setPeer(30274, dispatcher)`  (X-Layer)
- [ ] send-ULN `endpoint.setConfig(...)` for opBNB + X-Layer

Peers must be set on BOTH sides (here + each dest 3CP's `setPeer(30111, module)`) before recovery works.

---

## Phase 5 — Merge & record

- [ ] `audit/topup-factory-reinitializer` (#136) merges after its 3CP → master gets the reinitializer
- [ ] `feat/recovery-all-chains` PR merges (rebase on master post-#136 — reinitializer already there)
- [ ] `deployments/mainnet/<id>/deployments.json` committed with canonical factory + dispatcher per chain
- [ ] Generate Safe hashes for every 3CP (`./safe_hashes_from_json.sh`) into the 3CP-secure PR(s)

## Open blockers (gate go-live)

1. opBNB/X-Layer setConfig — built + OP send-side fork-proven; **receive side unconfirmed** until the Phase 0.5 dev round-trip.
2. Avalanche — **net-new**, and its DVN pathway unverified.
3. Polygon — gated on audit #136 landing.
