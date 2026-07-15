# Cash Lend dev deployment scripts

Dev-only scripts that upgrade the existing Optimism dev Cash deployment in place and route
it through the Aave v4 test instance via the LendGateway. The CLI sender must be the dev
admin (the Cash RoleRegistry owner, who is also the Aave test-instance admin).

## Run order

Deploy and check:

```sh
source .env && scripts/lend/check-pending-withdrawals.sh "$OPTIMISM_RPC"
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

Drop `--broadcast` to simulate any script first. Rollback stops if the test Spoke holds
more than $100 of aggregate supply or debt; set `SKIP_FUND_CHECK=true` to override.

`check-pending-withdrawals.sh` guards the module swap: a pending Cash withdrawal paying
out to an old liquid, liquidReferrer, or frax module would strand when the deploy replaces
them. It scans all Safes in parallel in about a minute; the same scan inside the forge
script took 20+ minutes, which is why it lives outside. Run it right before broadcasting.

## If a broadcast dies partway

Deploy only runs from a clean starting point, so do not rerun it directly. Instead:

1. Run `RollbackCashLendDev` — it skips references that are already restored.
2. Run `VerifyCashLendRollbackDev` to confirm the chain is back at the baseline.
3. Delete `deployments/dev/10/cash-lend.json`, then rerun the deploy.

Rollback itself can be rerun safely after a partial broadcast.

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
  configuration and swapping them in. The liquifier is behind a UUPS proxy and only gets a
  new implementation.
- **Driver**: a contract allowed to call the LendGateway's sandwich operations
  (`setDriver` on the gateway).
- **Sandwich**: the withdraw-from-Aave / act / re-supply-to-Aave wrapper the gateway puts
  around a module operation. See `docs/lend/CONTEXT.md`.
- **Dev policy**: the expected module permissions, hardcoded in
  `CashLendDevModules.requesterFlags`: all seven modules are default and whitelisted, and
  exactly liquid, liquidReferrer, and frax may request Cash withdrawals. Deploy asserts the
  chain matches before broadcasting; drift fails the run instead of being copied forward.
- **Spoke**: the Aave v4 test-instance contract holding reserves and positions.
