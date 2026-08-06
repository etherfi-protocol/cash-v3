# Cash Lend deployment scripts

Dev scripts upgrade the existing Optimism dev Cash deployment in place and route
it through the Aave v4 test instance via the LendGateway. The CLI sender must be the dev
admin (the Cash RoleRegistry owner, who is also the Aave test-instance admin).

## Prod (Gnosis bundle)

`DeployCashLendProd.s.sol` is the prod counterpart. The deployer EOA broadcasts only
unprivileged CREATE3 deployments (implementations, replacement modules, the atomically
initialized LendGateway proxy); every privileged call lands in
`output/CashLendProd-10.json` for the prod Safe (`0xA6cf...AAC4`) to execute via the
Gnosis tx builder. The script simulates the full bundle on the fork and asserts the end
state before anything is signed. Module policy (default / whitelisted / withdraw
requester) is mirrored from the live chain per module, and the bundle also carries the
Enso/Across module upgrades (trading-account.json), the safe-beacon RecoveryManager fix,
and the liquifier implementation upgrade.

Prerequisite: create `deployments/mainnet/10/summer-lend.json` with `.spoke` set to the
live Summer Lend Spoke from the AIP payload. If our Safe does not hold the Spoke admin
role, add `"skipPositionManagerTx": true` and have the Spoke admin (or the AIP payload)
call `updatePositionManager(<CREATE3 gateway address>, true)` instead — the gateway
address is deterministic, so it can be activated before the bundle executes.

```sh
# 1. EOA deployments + bundle generation + fork simulation (drop --broadcast to rehearse)
source .env && ENV=mainnet forge script scripts/lend/DeployCashLendProd.s.sol:DeployCashLendProd \
  --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv

# 2. Bytecode verification (any time after the EOA broadcast; read-only). The address checks in
#    VerifyCashLendProd prove WHO deployed (CREATE3 addresses derive from salts, not initcode);
#    this proves WHAT was deployed: every contract is redeployed locally from current source with
#    the same chain-mirrored constructor args and must match on-chain byte-for-byte (immutable
#    self-addresses and linked-library addresses are matched as consistent bindings, and the
#    linked libraries themselves are verified recursively).
source .env && ENV=mainnet forge script scripts/lend/VerifyCashLendProdBytecode.s.sol:VerifyCashLendProdBytecode \
  --rpc-url $OPTIMISM_RPC -vv

# 3. Safe signs & executes output/CashLendProd-10.json (Gnosis tx builder)

# 4. After execution, verify the live chain (all checks are requires). Runs BEFORE Safe execution
#    too: if the bundle's effects are not yet on-chain, it simulates output/CashLendProd-10.json
#    on the fork first and checks the simulated end state.
source .env && ENV=mainnet forge script scripts/lend/VerifyCashLendProd.s.sol:VerifyCashLendProd \
  --rpc-url $OPTIMISM_RPC -vvvv
```

The verify script recomputes every expected address from the CREATE3 salts
(`keccak256("CashLendProd.<Name>")`), so it detects a swapped-in implementation at an
unexpected address, not just a missing one. Old modules stay enabled for gradual
migration — run `check-pending-withdrawals.sh` before any later retirement pass, exactly
as on dev.

## Dev

## Run order

First refresh the Aave test-instance price feeds if the feed code changed since they were
last deployed (for example the USD-stable snap). The listing script is idempotent: on a
re-run it redeploys every feed and repoints each existing reserve instead of re-listing.
Afterwards, refresh the `details` oracle map in `aave-v4-test.json` by hand — the script
does not rewrite it.

```sh
source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
  scripts/aave-v4/AddSummerLendCollateral.s.sol:AddSummerLendCollateral \
  --rpc-url $OPTIMISM_RPC --broadcast -vvvv
```

Deploy and check:

```sh
source .env && ENV=dev forge script scripts/lend/DeployCashLendDev.s.sol:DeployCashLendDev \
  --rpc-url $OPTIMISM_RPC --broadcast -vvvv
source .env && ENV=dev forge script scripts/lend/VerifyCashLendDev.s.sol:VerifyCashLendDev \
  --rpc-url $OPTIMISM_RPC -vvvv
```

Roll back and check:

```sh
source .env && ENV=dev forge script scripts/lend/RollbackCashLendDev.s.sol:RollbackCashLendDev \
  --rpc-url $OPTIMISM_RPC --broadcast -vvvv
source .env && ENV=dev forge script scripts/lend/VerifyCashLendRollbackDev.s.sol:VerifyCashLendRollbackDev \
  --rpc-url $OPTIMISM_RPC -vvvv
```

Drop `--broadcast` to simulate any script first; a dry run skips writing
`cash-lend.json`, so it never blocks the real run. Rollback stops if the test Spoke holds
more than $100 of aggregate supply or debt; set `SKIP_FUND_CHECK=true` to override.

The deploy leaves the old modules enabled (default, whitelisted, requesters) so existing
Safes keep working while they migrate gradually; a later pass retires them.
`check-pending-withdrawals.sh` guards that retirement, not this deploy: a pending Cash
withdrawal paying out to an old liquid, liquidReferrer, or frax module would strand when
the old modules are disabled. It scans all Safes in parallel in about a minute; the same
scan inside the forge script took 20+ minutes, which is why it lives outside. Run it right
before broadcasting the retirement.

After the upgrade, new Safes must be set up with the four-field Cash setup payload that
carries the explicit `useLendGateway` flag. Coordinate with cash-be before it deploys
Safes against the upgraded dev stack, or Safe creation fails on the payload decode.

## If a broadcast dies partway

Forge writes `cash-lend.json` during the pre-broadcast simulation, before any transaction
is sent. If the broadcast dies before its first transaction, the next deploy run detects
the record as stale (no recorded address has code on-chain), discards it, and proceeds —
just rerun the deploy. If transactions landed, deploy refuses to rerun directly. Instead:

1. Run `RollbackCashLendDev` — it skips references that are already restored.
2. Run `VerifyCashLendRollbackDev` to confirm the chain is back at the baseline.
3. Delete `deployments/dev/10/cash-lend.json`, then rerun the deploy.

Rollback itself can be rerun safely after a partial broadcast. A redeploy after rollback
reuses the gateway proxy CashModule already references (its one-time `setLendGateway`
reference survives rollback) and upgrades it to the freshly compiled implementation.

## Files

- `deployments/dev/10/cash-lend-rollback-baseline.json` — **rollback baseline**: the
  committed pre-Lend implementation and module addresses. Deploy requires the chain to be
  exactly here before starting; Rollback restores to it.
- `deployments/dev/10/cash-lend.json` — **deployment record**: written by Deploy, read by
  both Verify scripts and Rollback. Delete it only after a verified rollback.
- `deployments/dev/10/aave-v4-test.json` — the dev Aave v4 test instance (Spoke and admin).

## Glossary

- **Old / new modules**: the seven immutable modules that move assets out of a Safe
  (openOcean, liquid, liquidReferrer, frax, stake, midas, beHype — always in that order).
  They cannot be upgraded, so Lend support means deploying new copies with the old
  configuration and enabling them alongside the old ones. The old modules stay enabled
  for gradual migration and are retired in a later pass. The liquifier is behind a UUPS
  proxy and only gets a new implementation.
- **Driver**: a contract allowed to call the LendGateway's sandwich operations
  (`setDriver` on the gateway).
- **Sandwich**: the withdraw-from-Aave / act / re-supply-to-Aave wrapper the gateway puts
  around a module operation. See `docs/lend/CONTEXT.md`.
- **Dev policy**: the expected module permissions, hardcoded in
  `CashLendDevModules.requesterFlags`: all seven modules are default and whitelisted, and
  exactly liquid, liquidReferrer, and frax may request Cash withdrawals. Deploy asserts the
  chain matches before broadcasting; drift fails the run instead of being copied forward.
- **Spoke**: the Aave v4 test-instance contract holding reserves and positions.
