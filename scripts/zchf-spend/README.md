# ZCHF debit spend (COR-1968)

Makes ZCHF (Frankencoin, `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` on Optimism) spendable by the card in Debit mode on both kinds of Cash safe, and gives it a settlement recipient on every settlement dispatcher. Swiss banking rail deposits arrive as ZCHF.

## Prerequisites (live on 2026-10-21)

- PriceProviderV2 prices ZCHF (OracleSink CHF / USD).
- ZCHF is a DebtManager collateral token.
- ZCHF is Summer Lend reserve 25 and registered on the LendGateway.
- The Operating Safe `0xA6cf…AAC4` holds `ADMIN_ROLE`, and is proposer and executor on the admin timelock `0x9AEb…7849` (8 hours), the only `ADMIN_TIMELOCK_ROLE` holder.

## Bundles

Both are for the Operating Safe on Optimism.

**1. `output/ConfigureZchfSpendOP3CP-10-schedule.json`**: `ADMIN_TIMELOCK.scheduleBatch`, 8 hours, salt `keccak256("ZchfDebitSpend.OP.SettlementRecipients.v1")`. The batch calls `setSettlementRecipients([ZCHF], [recipient])` on each dispatcher. The dispatchers accept only the admin timelock.

| Dispatcher | ZCHF recipient | Source |
|---|---|---|
| Rain `0x50A2…501C` | `0x4358f4940283E6357128941a5c508e5F314D79CB` | EURC's bridge `destRecipient` on this dispatcher, here on Optimism itself |
| Reap `0x9623…1Db2` | `0x4358f4940283E6357128941a5c508e5F314D79CB` | same |
| Pix `0x95aa…f42D` | `0x4358f4940283E6357128941a5c508e5F314D79CB` | same; also Pix's live USDT and USD₮0 recipient |
| CardOrder `0xb14F…766a` | ops wallet `0x86fBaEB3D6b5247F420590D303a6ffC9cd523790` | EURC's live recipient there |

**2. `output/ConfigureZchfSpendOP3CP-10-execute-and-spend.json`**, at least 8 hours after bundle 1. One MultiSend:

| # | Target | Call | Why |
|---|---|---|---|
| 1 | Admin timelock | `executeBatch`, same payload as bundle 1 | Lands the recipients |
| 2 | DebtManager `0x0078…9553` | `supportBorrowToken(ZCHF, 1, type(uint128).max)` | Legacy safes: `_sourceLegacyDebits` reverts `UnsupportedToken` unless `isBorrowToken`. Same config as USDT and USDT0: the max `minShares` floor blocks `supply`, so ZCHF cannot be borrowed. |
| 3 | LendGateway `0x01F8…03F4` | `setSpendAsset(ZCHF, true)` | Lend-gateway safes: `_sourceDebitToken` reverts `UnsupportedToken` unless `isSpendAsset`. |

Spending opens in the same transaction that sets the recipients, so ZCHF never reaches a dispatcher that has no recipient for it.

## Generate and rehearse

```sh
forge script scripts/zchf-spend/ConfigureZchfSpendOP3CP.s.sol --rpc-url $OPTIMISM_RPC
```

The script asserts the prerequisites, the EURC values it mirrors, and that no ZCHF recipient is set. It writes both bundles. Then, on the fork:

1. Shows a 10 USD ZCHF debit spend reverting on a live legacy Debit safe and a live lend-gateway Debit safe.
2. Shows a direct Operating Safe `setSettlementRecipients` call reverting.
3. Runs bundle 1, checks `executeBatch` reverts a minute before the delay, warps past it, then runs bundle 2.
4. Asserts the borrow config (no shares, no borrows), spend-set membership, and every ZCHF recipient.
5. Repeats both spends and checks the ZCHF lands in the Rain dispatcher.
6. Calls `settle(ZCHF)` as the live bridger on all four dispatchers and checks each recipient receives it.

Done when the run ends with `Simulation passed`.

## Not in scope

- Spending ZCHF in Credit mode (borrowing ZCHF), and ZCHF top-up rails.
- cash-be asset metadata, debit token preference ordering, and adding a ZCHF `settle` step to the settlement bridger.
