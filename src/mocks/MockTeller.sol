// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MockBoringVault } from "./MockBoringVault.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockTeller
 * @notice Minimal mock of the real sETHFI teller (`ILayerZeroTellerWithReferrer`) for tests
 *         that need a `deposit`-shaped external call without pulling in a fork of the real
 *         teller.
 * @dev Mirrors `ILayerZeroTellerWithReferrer`'s 4-arg `deposit` signature (depositAsset,
 *      depositAmount, minimumMint, referralAddress) plus its `vault()`/`shareLockPeriod()`/
 *      `isPaused()` getters, so it can be called through that interface. Delegates the asset
 *      pull and share mint to `shareToken.enter`, matching the real teller-to-vault flow, and
 *      computes shares at a configurable `rate`, net of an optional `premiumBps`, to simulate
 *      a teller-side share premium/fee. Enforces its own
 *      `minimumMint` check by default (mirroring the real teller), but that check can be
 *      disabled via `setEnforceMinimumMint` so tests can exercise the caller's own
 *      post-deposit slippage check instead. `shareLockPeriod`/`isPaused` are plain
 *      configurable state so tests can exercise `CashbackDistributor.setTeller`'s
 *      best-effort share-lock guard.
 */
contract MockTeller {
    /// @notice The share token minted on deposit.
    MockBoringVault public immutable shareToken;

    /// @notice Shares minted per unit of deposit asset, scaled by 1e18 (1e18 == 1:1 rate).
    uint256 public rate = 1e18;

    /// @notice Premium/fee in bps subtracted from the shares that would otherwise be minted.
    uint16 public premiumBps;

    /// @notice Whether this mock enforces `minimumMint` itself (mirroring the real teller).
    bool public enforceMinimumMint = true;

    /// @notice Mirrors the real teller's `shareLockPeriod()` getter.
    uint64 public shareLockPeriod;

    /// @notice Mirrors the real teller's `isPaused()` getter.
    bool public isPaused;

    constructor(MockBoringVault _shareToken) {
        shareToken = _shareToken;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setPremiumBps(uint16 _premiumBps) external {
        premiumBps = _premiumBps;
    }

    function setEnforceMinimumMint(bool _enforce) external {
        enforceMinimumMint = _enforce;
    }

    function setShareLockPeriod(uint64 _shareLockPeriod) external {
        shareLockPeriod = _shareLockPeriod;
    }

    function setPaused(bool _isPaused) external {
        isPaused = _isPaused;
    }

    /// @notice Mirrors the real teller's `vault()` getter: the vault IS the share token.
    function vault() external view returns (address) {
        return address(shareToken);
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint, address referralAddress) external payable returns (uint256 shares) {
        referralAddress; // unused; mirrors the real teller's 4-arg signature

        shares = (depositAmount * rate) / 1e18;
        shares -= (shares * premiumBps) / 10_000;

        if (enforceMinimumMint && shares < minimumMint) revert("MockTeller: minimumMint not met");

        shareToken.enter(msg.sender, depositAsset, depositAmount, msg.sender, shares);
    }
}
