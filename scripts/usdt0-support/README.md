# USD₮0 support on Optimism — settlement, Summer Lend gateway, cross-chain withdrawals (3CP-699)

The third and last leg of USD₮0 (`0x01bF…1071`, `USD₮0`, 6 decimals) support. 695 made it hold-able
and spendable and pointed the Ethereum / Arbitrum / HyperEVM top-up rails at it; 698 gave it a Summer
Lend reserve. This leg lets the money **leave** again.

| | Call | Routing |
|---|---|---|
| Settlement | `setSettlementRecipients([USDT0], [<that dispatcher's live USDT recipient>])` on **Rain**, **Reap** and **Pix** | 8h `ADMIN_TIMELOCK` (schedule → 8h → execute) |
| Withdrawals | `StargateModule.setAssetConfig([USDT0], [(isOFT true, pool = the OP USD₮0 OFT)])` | direct from the Operating Safe |
| Summer Lend | `LendGateway.setReserveId(USDT0, 23)` then `setSpendAsset(USDT0, true)` | direct from the Operating Safe |

Nothing is deployed. No funds move. Every recipient is **mirrored from the live USDT config**, never
chosen, and the generator asserts that before it writes any calldata.

## Why the split routing

The deployed `SettlementDispatcher` implementations are ahead of `src/` — they check
`ADMIN_TIMELOCK_ROLE`, not `onlyRoleRegistryOwner`. Read live 2026-09-24:

| Caller of `setSettlementRecipients` | Result |
|---|---|
| Operating Safe `0xA6cf…AAC4` | reverts `OnlyAdminTimelock()` (`0x7010de69`) |
| registry owner timelock `0x9106cD76…` | reverts `OnlyAdminTimelock()` |
| `ADMIN_TIMELOCK` `0x9AEb8eaa…7849` (`getMinDelay()` = 28800) | **succeeds** |

The other way round for the other two: the Safe holds `STARGATE_MODULE_ADMIN_ROLE` and
`LEND_GATEWAY_ADMIN_ROLE`, and the timelock holds neither (`Unauthorized()`, `0x82b42900`). Neither
choice is stylistic.

## CardOrder is left out on purpose

There are four dispatchers. **CardOrder** `0xb14FDfd7…2F766a` has no settlement recipient for USDT or
USDC today, and settlement-bridger skips `PhysicalCardOrders` for `settle()` entirely — it only tops
up the physical-card refund wallet. "The same as USDT" means "nothing" there. The generator asserts
CardOrder still has no USDT recipient, so the day that changes this omission stops being silent.

## Ordering

```sh
# ── generate + rehearse (read-only, any time; needs only an OP RPC) ─────────────────────────────
forge script scripts/usdt0-support/ConfigureUsdt0Support3CP.s.sol --rpc-url $OPTIMISM_RPC
```

One run writes all three bundles into `output/usdt0-support/` and simulates them in signing order on
a fork: bundle 1 → `warp +8h` → bundle 2 → (a fork rehearsal of 698's USDT0 listing, while reserve 23
is not live) → bundle 3, with the post-state read back and all three withdrawal routes quoted end to
end through the real LayerZero endpoint.

```sh
# ── sign, in this order (Operating Safe 0xA6cf…AAC4, OP) ───────────────────────────────────────
# 1. nonce 116  output/usdt0-support/settlement-stargate-schedule.json  (scheduleBatch + setAssetConfig)
# 2. nonce 117  output/usdt0-support/settlement-execute.json            (executeBatch, >= 8h later)
# 3. nonce 118  output/usdt0-support/lend-gateway.json                  (setReserveId + setSpendAsset)
```

**What must be true when:**

1. Bundle 1 is signable now. It depends on nothing.
2. Bundle 3 needs **3CP-698 executed**: `setReserveId` reverts `ReserveAssetMismatch()` until reserve
   23 exists, and `setSpendAsset` reverts `AssetNotRegistered(USDT0)` without `setReserveId` before it.
3. **Bundle 2 before bundle 3**, so USDT0 has somewhere to settle before it becomes a lend spend
   asset. Safe nonces enforce it; the ordering is the reason for the nonce assignment, not a
   by-product of it.
4. Two things make no transaction here revert but leave it inert:
   - the StargateModule config does nothing until **695** puts USDT0 in
     `CashModule.whitelistedWithdrawAssets` (`requestBridge` → `requestWithdrawalByModule` reverts
     `InvalidWithdrawAsset` otherwise);
   - the settlement recipients are never read until **settlement-bridger** ships a USDT0 settle step.
     Recipients first is the right order: the other way round, every 30-minute run reverts
     `SettlementRecipientNotSet` and pages.

## Conflict to clear

`scripts/zchf-usdt0-paxgy/ConfigureZchfUsdt0PaxgyCashOP3CP.s.sol` still carries USDT0's
`PriceProviderV2.setTokenConfig`, `DebtManager.supportCollateralToken` and `LendGateway.setReserveId`
rows. 695 and this proposal now own all three. Once 695 has executed, regenerating that bundle
produces a batch that reverts **in full** — `_supportCollateralToken` reverts
`AlreadyCollateralToken()` on the USDT0 leg and takes ZCHF and PAXGy down with it. Drop the USDT0 rows
from that script before its bundle is regenerated.

## The one thing to read twice

A USDT0 withdrawal to **Ethereum is delivered as native USDT**. eid 30101's peer
`0x6C96dE32…41dee` is an OFT *adapter* over `0xdAC17F95…31ec7`, holding a ~3.4bn USDT lockbox — the
same lockbox 695's Ethereum top-up rail mints against. There is no USDT0 on Ethereum to receive
instead, so this is the mesh working correctly, but the product surface has to say so: cash-be's
USDT0 entry has no mainnet address, and its `memberWithdraw` lane is declared explicitly rather than
inferred from address presence for exactly this reason. Arbitrum (30110) and HyperEVM (30367) deliver
USDT0.

Other facts worth having read: the OP OFT's `approvalRequired()` is `false` (it burns from the sender,
so no allowance leg), `sharedDecimals()` is 6 = USDT0's decimals (so no OFT dust truncation on this
asset), and it exposes no rate limiter.

## Dev

`ConfigureUsdt0SupportDev.s.sol` is the dev counterpart. It is **two calls and an EOA broadcast**, not
three Safe transactions, because dev differs in two ways:

1. **No timelock.** `ADMIN_ROLE` and `ADMIN_TIMELOCK_ROLE` have no holders on the dev RoleRegistry —
   the cash-v3#289 re-gating that reached prod has not reached dev — so the dev dispatchers still
   check `onlyRoleRegistryOwner`, and the owner is the deployer EOA `0x7D829d50…DC6E`. There is no dev
   equivalent of the schedule/execute pair.
2. **The lend-gateway leg is already live.** USD₮0 is already a registered dev gateway reserve and
   already a spend asset, so the third prod transaction has nothing to do. The script asserts that
   instead of repeating it, and prints the dev reserve id, which is **28**, not prod's 23 — dev listed
   different assets in a different order, so the id is never assumed to match across environments.

Also unlike prod, **every** dev dispatcher settles USDT, CardOrder included, so all four get a
recipient (`0x7D829d50…DC6E` on each). The list is derived from each dispatcher's live
`getSettlementRecipient(USDT)` rather than hardcoded, which is the same mirroring rule the prod
generator uses — it is what makes the two scripts agree without sharing a recipient table, and it is
why the same code yields four dispatchers on dev and three on prod.

```sh
# rehearse on a fork — no key needed, pranks the dev RoleRegistry owner
ENV=dev forge script scripts/usdt0-support/ConfigureUsdt0SupportDev.s.sol:ConfigureUsdt0SupportDev   --sig 'rehearse()' --rpc-url $OPTIMISM_RPC

# broadcast
source .env && ENV=dev forge script scripts/usdt0-support/ConfigureUsdt0SupportDev.s.sol:ConfigureUsdt0SupportDev   --rpc-url $OPTIMISM_RPC --broadcast -vvvv

# read-only re-check
ENV=dev forge script scripts/usdt0-support/ConfigureUsdt0SupportDev.s.sol:ConfigureUsdt0SupportDev   --sig 'verify()' --rpc-url $OPTIMISM_RPC
```

## Where things are pinned

`scripts/usdt0-support/Usdt0SupportProdConfig.sol` — dispatchers, recipients, the OFT and its peers,
the timelock salt, reserve id 23, and the USDT0 Summer Lend parameters the fork rehearsal replays
(aave-v4 `AaveV4EtherfiCash.sol` remains their source of truth; they are here only so the rehearsal
can run before 698 has executed). The shared Summer Lend topology — hub, spoke, configurators,
treasury spoke, IR strategy — comes from `scripts/wspyx-paxg/WspyxPaxgProdConfig.sol`.

Deliberately no dependency on `scripts/zchf-usdt0-paxgy/`: that directory lives on an unmerged
branch, so importing it would only compile for whoever has that branch checked out.
