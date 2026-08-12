# Vendored Aave price cap adapters

Every `.sol` file in this directory except `IACLManager.sol` is copied **verbatim** from Aave's
official price feed repository:

- Repository: <https://github.com/aave-dao/aave-price-feeds>
- Commit: `ff9f24a7c7d0cc67b70b5319f20abdb0a5c2f2df`
- Author: BGD Labs / Aave Labs
- Licence: BUSL-1.1 / MIT as declared per file (unchanged)

| File here | Upstream path |
| --- | --- |
| `PriceCapAdapterBase.sol` | `src/contracts/PriceCapAdapterBase.sol` |
| `PriceCapAdapterStable.sol` | `src/contracts/PriceCapAdapterStable.sol` |
| `CLRatePriceCapAdapter.sol` | `src/contracts/CLRatePriceCapAdapter.sol` |
| `EURPriceCapAdapterStable.sol` | `src/contracts/misc-adapters/EURPriceCapAdapterStable.sol` |
| `OneUSDFixedAdapter.sol` | `src/contracts/misc-adapters/OneUSDFixedAdapter.sol` |
| `IPriceCapAdapter.sol` | `src/interfaces/IPriceCapAdapter.sol` |
| `IPriceCapAdapterStable.sol` | `src/interfaces/IPriceCapAdapterStable.sol` |
| `IEURPriceCapAdapterStable.sol` | `src/interfaces/IEURPriceCapAdapterStable.sol` |
| `ICLSynchronicityPriceAdapter.sol` | `src/interfaces/ICLSynchronicityPriceAdapter.sol` |
| `IChainlinkAggregator.sol` | `src/interfaces/IChainlinkAggregator.sol` |
| `IBasicFeed.sol` | `src/interfaces/IBasicFeed.sol` |
| `IExtendedFeed.sol` | `src/interfaces/IExtendedFeed.sol` |

## The only edits

1. **Import paths flattened.** Upstream keeps contracts and interfaces in separate directories;
   here they sit side by side, so `'../interfaces/X.sol'` became `'./X.sol'`. No identifiers,
   pragmas, or logic changed.
2. **`aave-address-book/AaveV3.sol` replaced with the local `IACLManager.sol`.** The adapters use
   exactly two members of that interface (`isRiskAdmin`, `isPoolAdmin`); importing the address book
   would pull in the entire aave-v3-origin interface tree for two function signatures. See the
   natspec in `IACLManager.sol`.

Nothing else was touched. To verify:

```sh
git clone https://github.com/aave-dao/aave-price-feeds /tmp/apf
cd /tmp/apf && git checkout ff9f24a7c7d0cc67b70b5319f20abdb0a5c2f2df
diff <(sed "s|'\.\./interfaces/|'./|; s|'aave-address-book/AaveV3.sol'|'./IACLManager.sol'|" \
        src/contracts/PriceCapAdapterBase.sol) \
     <path-to-this-dir>/PriceCapAdapterBase.sol
```

## Why vendored rather than a submodule

`aave-price-feeds` depends on `aave-address-book`, which depends on `aave-v3-origin`, which depends
on `solidity-utils`. Initialising that chain takes minutes and adds hundreds of megabytes for two
function signatures. If Aave's review prefers an unmodified submodule, the swap is mechanical:
add the submodule, add the `aave-address-book/` remapping, and delete this directory.
