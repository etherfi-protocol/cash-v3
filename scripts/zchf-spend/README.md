# ZCHF debit spend (COR-1968)

Makes ZCHF (Frankencoin, `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` on Optimism) spendable by the card in Debit mode on both kinds of Cash safe. Swiss banking rail deposits arrive as ZCHF.

## Prerequisites (live on 2026-10-21)

- PriceProviderV2 prices ZCHF (OracleSink CHF / USD, 1.212077 at generation).
- ZCHF is a DebtManager collateral token.
- ZCHF is Summer Lend reserve 25 and registered on the LendGateway.
- The Operating Safe `0xA6cf…AAC4` holds `ADMIN_ROLE` on the Optimism RoleRegistry.

## Bundle

Operating Safe, Optimism, `output/ConfigureZchfSpendOP3CP-10.json`, two calls:

| # | Target | Call | Why |
|---|---|---|---|
| 1 | DebtManager `0x0078…9553` | `supportBorrowToken(ZCHF, 1, type(uint128).max)` | Legacy safes: `_sourceLegacyDebits` reverts `UnsupportedToken` unless `isBorrowToken`. Same config as USDT and USDT0: the max `minShares` floor blocks `supply`, so ZCHF cannot be borrowed. |
| 2 | LendGateway `0x01F8…03F4` | `setSpendAsset(ZCHF, true)` | Lend-gateway safes: `_sourceDebitToken` reverts `UnsupportedToken` unless `isSpendAsset`. |

## Generate and rehearse

```sh
forge script scripts/zchf-spend/ConfigureZchfSpendOP3CP.s.sol --rpc-url $OPTIMISM_RPC
```

The script asserts the prerequisites, writes the bundle, and on the fork:

1. Shows a 10 USD ZCHF debit spend reverting on a live legacy Debit safe and a live lend-gateway Debit safe.
2. Executes the bundle as the Operating Safe.
3. Asserts the borrow config (no shares, no borrows) and spend-set membership.
4. Repeats both spends and checks the ZCHF lands in the Rain settlement dispatcher.

Done when the run ends with `Simulation passed`.

## Not in scope

- Settlement recipients for ZCHF on the dispatchers. None is set today; EURC is a live spend asset without one too, so ops moves dispatcher balances.
- Spending ZCHF in Credit mode (borrowing ZCHF), and ZCHF top-up rails.
- cash-be asset metadata and debit token preference ordering.
