// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Utils } from "../utils/Utils.sol";

/**
 * @title StockWrapProdConfig
 * @author ether.fi
 * @notice Shared configuration for the Ethereum **prod** raw-xStock redirect-wrapping rollout: the
 *         two deployed implementations the 3CP upgrades to, the `TopUpV2` constructor arguments,
 *         and the Safe.
 *
 * @dev The rollout is three owner-gated calls on the prod `TopUpFactory`, and their ORDER is
 *      load-bearing: a `TopUp` impl asks its owner for `wrapperFor(token)`, so a beacon upgraded
 *      ahead of the factory would revert `redirectToTradingSafe` on all 83,000+ live prod TopUp
 *      proxies until the factory caught up. Factory first, beacon second, configuration last —
 *      which is why they ship as ONE Safe bundle rather than three signings.
 *
 * @dev Implementations are deployed with plain `new` (no CREATE3), matching the dev rollout script
 *      and `scripts/recovery/DeployTopUpV2Impl.s.sol`: they are stateless and referenced only by
 *      the proxy/beacon slots, so a deterministic address buys nothing. The flip side is that the
 *      addresses are nonce-dependent and cannot be known before the broadcast, so they are pinned
 *      here AFTER the fact. **If either is ever redeployed, update the constant below** — the 3CP
 *      generator and the bytecode verifier both read these, and everything that matters about them
 *      is re-derived from the chain rather than trusted.
 */
abstract contract StockWrapProdConfig is Utils {
    // ---- Deployed implementations (Ethereum mainnet, block 25753168) ----

    /// @notice `TopUpFactory` implementation carrying `wrapperFor` / `setRedirectWrappers`.
    ///         Deployed 2026-08-14, tx 0xd039a228d60412006fe7d5a0ad408a606316709860768436cb6e66eec86938ac.
    address internal constant TOPUP_FACTORY_IMPL = 0x8546090Ad12bCF8ce0b0154d044792D4cd10714c;
    /// @notice `TopUpV2` implementation for the beacon, built with (WETH, RECOVERY_DISPATCHER).
    ///         Deployed 2026-08-14, tx 0xe32c77791806bbc8f23fc5bd05123cdc01a92ebf9914d2e43a6c2a21c8cd4b13.
    address internal constant TOPUP_V2_IMPL = 0xcA4930163F2FEa9cebf9aEa437832c3C408A8491;

    // ---- Chain constants (Ethereum mainnet) ----

    /// @notice WETH — `TopUp`'s immutable, used to wrap native top-ups.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @notice `AssetRecoveryDispatcher` — `TopUpV2`'s immutable `DISPATCHER`, the only caller
    ///         allowed to `executeRecovery`. Wired to the same RoleRegistry as the TopUpFactory.
    address internal constant RECOVERY_DISPATCHER = 0x418e0af7c750Ba5cbffC5C2a8398591755926A29;

    /// @notice Prod Safe (OperatingSafe). Owns the Ethereum RoleRegistry, so it can make all three
    ///         calls directly — `onlyRoleRegistryOwner` for the beacon upgrade and
    ///         `setRedirectWrappers`, and `onlyUpgrader` (an `owner()` check) for the UUPS factory
    ///         upgrade. No timelock on this chain.
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
}
