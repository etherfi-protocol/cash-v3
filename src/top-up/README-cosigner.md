# Top-up payout co-signatures

This change adds approval checks only. It does not deploy a contract, activate enforcement, create a KMS key or implement the validator.

## Keep completed top-ups completed

`getTxId(txHash, user, token)` remains `keccak256(abi.encode(txHash, user, token))`.
The completion mapping, its storage slot, getters, events and `_topUp` behavior stay unchanged.
No completion records or worker database IDs are migrated.

The approval digest is a separate EIP-712 message, never a replacement completion ID.
A fresh approval cannot pay the same completed top-up again, including with a different amount or source chain.
The existing ID's omission of source chain remains unchanged; this PR does not attempt to redesign deduplication.

## Signing interface

Domain:
- name: `EtherFiTopUpDest`
- version: `1`
- chainId: destination chain ID
- verifyingContract: destination proxy address

Type (field order matters):

```text
TopUpApproval(bytes32 txHash,address user,uint256 sourceChainId,address token,uint256 amount,uint256 deadline,uint256 epoch)
```

`TopUpApproval` calldata contains the first six fields. Read `epoch` from `cosignerConfig()`.
`getTopUpApprovalDigest(approval)` returns the full digest for the current epoch.
Amounts are destination token base units; stock payouts use the approved share amount.
The validator must independently check deposit eligibility, recipient, token mapping and amount before signing.

Use a secp256k1 KMS signing key, sign the digest without hashing it again, convert DER to Ethereum's 65-byte `r || s || v`, normalize low-s and recover the configured signer to determine `v` (27/28).
No Ethereum personal-message prefix is used. Signature conversion belongs to the validator, not this contract.

## Calls

- `topUpUserSafeWithApproval(approval, signature)`: one payout.
- `topUpUserSafeBatchWithApproval(approvals, signatures)`: one approval per item; any failure reverts the whole batch.
- Both retain `TOP_UP_ROLE`, pause and reentrancy checks.
- Signed methods verify approvals even while legacy enforcement is disabled.
- `deadline` is inclusive. Expired or malformed approvals revert.

The existing unsigned methods work only while enforcement is disabled.
There is no unsigned asset exception when enforcement is enabled.
Stock payouts use the same checks. Separate `wrapStock`, admin withdrawal and other fund-moving operations are outside this approval scope.
Lending after payout keeps its existing self-only, best-effort behavior.

## Administration and rollout

`configureCosigner(signer, required)` uses the existing `ADMIN_TIMELOCK_ROLE`.
Enabling requires a nonzero signer. Every configuration call increments the epoch and emits `CosignerConfigured`, invalidating outstanding approvals even if a previous key is restored.

1. Review contracts and the validator schema; run local and deployed-state fork checks.
2. Upgrade through existing governance. Appended storage defaults to enforcement off.
3. Configure the KMS public-key-derived address with enforcement off.
4. Run validator shadow checks, then deploy compatible workers using signed methods.
5. Confirm every worker sharing this destination contract is compatible.
6. Enable enforcement through governance; workers must refresh approvals for the new epoch.
7. Alert on configuration changes and sustained payout/approval failures.

The switch is global to this proxy, not per source chain. Source-chain-only rollout is not supported by this initial contract implementation.
For an emergency, governance can set `required=false`; this restores unsigned methods and deliberately removes co-signature protection. Completion records remain intact. Re-enabling requires fresh approvals.

## Validation

```sh
forge test --match-path test/top-up/TopUpDestCosigner.t.sol -vv
```

The local suite upgrades a proxy from the frozen pre-change implementation and checks prior completion records, signed payouts, field/domain binding, rotation, legacy bypass rejection, roles, pause, batch rollback, stocks and lending.
The fixture is copied from `ac89a4b94db4bd0c0b5dc0421137dd3afa1d7bc1:src/top-up/TopUpDest.sol`; only its contract name and relative imports differ.

Before activation, also run existing TopUpDest tests and a fork upgrade against the intended deployed implementation. No live deployment is performed by this PR.
