# Safe Proxy Deployment & Upgrade

When writing deployment or upgrade scripts for smart contracts in this repo, you MUST follow these rules. They exist because a MEV bot hijacked our CashModule proxy on Optimism by front-running the `initialize()` call.

## Proxy Deployment Rules

### 1. ALWAYS initialize a proxy in the same transaction as deployment

This is the most important rule. It applies to ALL proxy deployments — deterministic or not.

- Pass init calldata as the second argument to the proxy constructor.
- NEVER deploy with empty init data (`""`) and call `initialize()` separately — this creates a window where anyone can front-run the init and take ownership.

```solidity
// WRONG — front-runnable, regardless of how the proxy is deployed
proxy = new UUPSProxy(impl, "");
proxy.initialize(args);  // MEV bot calls this first!

// CORRECT — atomic deploy + init, no front-running possible
proxy = new UUPSProxy(impl, abi.encodeCall(Contract.initialize, (args)));
```

### 2. When there are circular dependencies, use deterministic deploys with address prediction

If contracts reference each other (e.g. DataProvider needs CashModule and CashModule needs DataProvider), use CREATE2 or CREATE3 to precompute addresses and break the cycle. Non-deterministic deploys (`new`) are fine when there are no circular dependencies, as long as Rule 1 is followed.

```solidity
Predicted memory p = _predictAll();  // precompute all addresses from salts

cashModule = deployCreate3(
    abi.encodePacked(type(UUPSProxy).creationCode,
        abi.encode(cmImpl, abi.encodeCall(CashModule.initialize, (p.dataProvider, ...)))),
    SALT_CASH_MODULE_PROXY
);
```

## Immutable-Style Upgrades (Constructor Params)

### 3. Verify every constructor parameter

Most protocol upgrades use immutable-style patterns where critical addresses are set in the constructor. For every `new Contract(...)` deployment, check:

- **Correct order** — constructor args must match the constructor signature exactly. A swapped `address` param silently compiles but points to the wrong contract.
- **Correct value** — each address must be the right contract for the current chain. Cross-check against `deployments.json` or fixtures.
- **No zero addresses** — unless explicitly intended.

```solidity
// constructor(address _cashModule, address _dataProvider) — order matters!
new CashLens(cashModule, dataProvider);  // correct
new CashLens(dataProvider, cashModule);  // WRONG — args swapped, compiles fine
```

### 4. For already-deployed impls, verify constructor params via bytecode comparison

Use the `ContractCodeChecker` pattern (see `scripts/utils/ContractCodeChecker.sol`) to deploy locally with the same constructor args and compare bytecode against the on-chain impl:

```solidity
// Pattern from test/upgrade-bytecode-verification/
CashModuleCore localDeploy = new CashModuleCore(dataProvider);
verifyContractByteCodeMatch(deployedImplAddress, address(localDeploy));
```

Reference: `test/upgrade-bytecode-verification/` contains examples (e.g., `UpgradePix.t.sol`).

## Storage Layout Safety

### 5. Run storage layout check before any upgrade

Compare the storage layout of old and new implementations. Storage slot collisions silently corrupt proxy state.

```bash
forge inspect OldContract storageLayout > old_layout.json
forge inspect NewContract storageLayout > new_layout.json
diff old_layout.json new_layout.json
```

Rules:
- New storage variables must only be APPENDED, never inserted
- No existing variable can change type (e.g., `uint256` to `address`)
- No existing variable can be removed or reordered
- For ERC-7201 namespaced storage, append new fields to end of struct
- Gap variables (`uint256[50] __gap`) must be decremented when new fields are added

## Timelock & Ownership Safety

### 6. Post-operation hook: verify timelock owner is unchanged

Every deployment or upgrade script MUST verify that the timelock owner/admin has not changed after execution. If a malicious transaction was injected into a timelock batch, it could transfer ownership mid-execution.

```solidity
// MUST be the last check — after all operations complete
address currentOwner = RoleRegistry(ROLE_REGISTRY).owner();
require(currentOwner == expectedOwner, "CRITICAL: timelock owner changed!");
```

This is critical because a timelock batch can contain multiple operations — if an attacker injects a `transferOwnership()` call into the middle of a batch, all subsequent operations execute under the attacker's control, and the change is invisible unless explicitly checked.

## Implementation Address Verification

### 7. ALWAYS deploy impls via CREATE3 with deterministic salts

Implementation contracts MUST be deployed via CREATE3 with a deterministic salt so that verification scripts can confirm the EIP-1967 impl slot contains the exact expected address. This catches attacks where someone deploys a different impl at an unexpected address.

```solidity
// Use a descriptive salt for the impl
bytes32 constant SALT_MY_CONTRACT_IMPL = keccak256("MyDeployScript.MyContractImpl");

// Deploy impl via CREATE3 (NOT regular `new`)
address impl = deployCreate3(
    abi.encodePacked(type(MyContract).creationCode, abi.encode(arg)),
    SALT_MY_CONTRACT_IMPL
);

// Verification: check the proxy's impl slot matches the predicted address
address expectedImpl = CREATE3.predictDeterministicAddress(SALT_MY_CONTRACT_IMPL, NICKS_FACTORY);
address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
require(actualImpl == expectedImpl, "impl address mismatch");
```

Reference: `scripts/ReserveAddresses.s.sol` and `scripts/VerifyReservedAddresses.s.sol`.

## Post-Deployment Verification

### 8. Every deployment script MUST have a companion verification script

When writing a deployment script (e.g., `scripts/SetupFoo.s.sol`), you MUST also write a corresponding verification script (e.g., `scripts/VerifyFoo.s.sol`) that runs against the live chain AFTER broadcast txs confirm. This is NOT optional.

The verification script MUST use `require()` for every check — never just log `[FAIL]` and continue. The script must revert on any failure so the exit code is non-zero and CI/wrappers can trust it.

The verification script MUST check for every deployed proxy:

- **EIP-1967 impl slot** contains the EXACT predicted CREATE3 impl address (computed from the impl salt + Nick's factory). Not just non-zero — the exact address. This confirms no one swapped in a malicious impl.
- **Ownership** — roleRegistry in storage slot `0xa5586bb7...f500` points to OUR RoleRegistry (hijack detection)
- **Initialized** — OZ Initializable slot is > 0 (but this alone is NOT sufficient — attacker init also sets it)
- **Cross-references** — contracts that reference each other (e.g., DataProvider.getCashModule()) return the correct addresses

```solidity
// Pattern: verify impl address matches what we deployed via CREATE3
address expectedImpl = CREATE3.predictDeterministicAddress(SALT_MY_CONTRACT_IMPL, NICKS_FACTORY);
address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
require(actualImpl == expectedImpl, "impl address mismatch — possible hijack");
```

The verification script must be runnable independently without broadcasting:
```bash
forge script scripts/VerifyFoo.s.sol --rpc-url <LIVE_RPC>
```

Reference: `scripts/VerifyReservedAddresses.s.sol`, `scripts/VerifyOptimismProd.s.sol`.

### 9. Make deployment scripts idempotent

- Check if a contract already exists at the predicted address and skip if so.
- This allows safe re-runs if a deployment partially fails.

## Background: The CashModule Incident

On Optimism dev, CashModule proxy was deployed with empty init data due to a circular dependency between DataProvider and CashModule. A MEV bot front-ran `initialize()` within 1 block, gaining permanent control of the upgrade path via a fake roleRegistry. The proxy was unrecoverable and had to be abandoned and redeployed at a new address.
