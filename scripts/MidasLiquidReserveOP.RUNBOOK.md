# OP MidasModule for liquidRESERVE — Runbook

Configures the **existing** [`MidasModule`](../src/modules/midas/MidasModule.sol) at
`0x2D43400058cE6810916Fd312FB38a7DcdF9708aa` for the Midas liquidRESERVE product on
Optimism (chainId 10).

No new deployment is needed. The script:

1. Registers the MidasModule as a **default module** on `EtherFiDataProvider`.
2. Grants **`MIDAS_MODULE_ADMIN`** role to the `cashControllerSafe` on `RoleRegistry`.
3. Calls **`addMidasVaults`** on the MidasModule with liquidRESERVE deposit/redemption vaults.
4. Sets the **price oracle** for liquidRESERVE on `PriceProvider`.
5. Supports liquidRESERVE as **collateral** and **borrow** token on `DebtManager`.
6. Whitelists liquidRESERVE as a **withdrawable asset** on `CashModule`.

## Addresses

| Name | Address |
|------|---------|
| MidasModule (existing) | `0x2D43400058cE6810916Fd312FB38a7DcdF9708aa` |
| liquidRESERVE token | `0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898` |
| Price oracle (chainlink) | `0x58dDf77A329CcbE2F4C2114C64ed9E12Ec8a1356` |
| Deposit vault | `0xcA1C871f8ae2571Cb126A46861fc06cB9E645152` |
| Redemption vault | `0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25` |
| cashControllerSafe | `0xA6cf33124cb342D1c604cAC87986B965F428AAC4` |
| MIDAS_MODULE_ADMIN role | `0x57bb90935cfaf88839f01bfa8de28ad30d80741c4cc93a5d12373ddbb95c68c0` |

## Run — direct broadcast (broadcaster holds all admin roles)

```bash
ENV=mainnet PRIVATE_KEY=$PRIVATE_KEY \
forge script scripts/DeployMidasModuleLiquidReserveOP.s.sol:DeployMidasModuleLiquidReserveOP \
  --rpc-url $OPTIMISM_RPC --broadcast -vvvv
```

## Run — Safe bundle (cashControllerSafe executes all config)

```bash
ENV=mainnet \
forge script scripts/gnosis-txs/DeployMidasModuleLiquidReserveOP.s.sol:DeployMidasModuleLiquidReserveOPGnosis \
  --rpc-url $OPTIMISM_RPC -vvvv
```

Without `--broadcast` the gnosis-txs script generates the JSON bundle and **simulates**
it on the live fork, asserting:

- `isDefaultModule(midasModule) == true`
- `isCollateralToken(token) == true`
- `hasRole(MIDAS_MODULE_ADMIN, safe) == true`
- `vaults(token) == (depositVault, redemptionVault)`

Bundle is written to `output/DeployMidasModuleLiquidReserveOP.json`.

## Post-execution

1. Update [`deployments/mainnet/10/deployments.json`](../deployments/mainnet/10/deployments.json)
   to include the MidasModule address:

   ```json
   "MidasModule": "0x2D43400058cE6810916Fd312FB38a7DcdF9708aa"
   ```

2. Run the existing OP config sanity test to confirm everything is wired:

   ```bash
   TEST_CHAIN=10 forge test --match-contract VerifyOPConfig -vv
   ```
