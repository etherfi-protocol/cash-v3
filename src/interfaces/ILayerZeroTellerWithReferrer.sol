// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ILayerZeroTellerWithReferrer
 * @notice Minimal interface for the BoringVault-style teller used by
 *         `CashbackDistributor.awardStaked` to stake ETHFI into sETHFI.
 * @dev Sibling of `ILayerZeroTeller`, not a replacement for it: `ILayerZeroTeller` declares a
 *      stale 3-arg `deposit` that does not match the real sETHFI teller's deployed bytecode
 *      (verified on-chain at 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b -- the 3-arg `deposit`
 *      selector is absent). The real teller's `deposit` takes a 4th `referralAddress` argument,
 *      hence the "WithReferrer" naming, matching this repo's existing convention (see
 *      `EtherFiLiquidModuleWithReferrer`). `ILayerZeroTeller` is left unmodified since other
 *      code in this repo depends on its (for other tellers, correct) 3-arg shape.
 *
 *      The real teller also exposes `bulkDeposit(ERC20, uint256, uint256, address)`, which would
 *      let a single caller deposit on behalf of many recipients in one call. It is intentionally
 *      not declared/used here: it is gated by Solmate `Auth`, and using it would require the
 *      vault's Authority to grant this distributor a role -- an additional vault-side
 *      permission outside this contract's scope. `awardStaked` uses plain `deposit` instead,
 *      which requires no such grant.
 */
interface ILayerZeroTellerWithReferrer {
    /**
     * @notice Deposits `depositAmount` of `depositAsset`, minting at least `minimumMint` shares
     *         to the caller (`msg.sender`).
     * @param depositAsset The asset being deposited.
     * @param depositAmount The amount of `depositAsset` to deposit.
     * @param minimumMint The minimum acceptable shares to mint (the teller's own slippage check).
     * @param referralAddress Referral address; CashbackDistributor always passes `address(0)`.
     * @return shares The shares minted to the caller.
     */
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint, address referralAddress) external payable returns (uint256 shares);

    /**
     * @notice The BoringVault this teller deposits into.
     * @dev For this teller, the vault IS the share token: `vault()` returns the same address as
     *      the sETHFI token itself (verified on-chain for the real teller). Callers configuring
     *      a teller should check `vault() == <expected share token>` to catch a misconfigured
     *      teller pointed at the wrong vault.
     */
    function vault() external view returns (address);

    /**
     * @notice The share lock period, in seconds, enforced after a deposit.
     * @dev Must be zero for `CashbackDistributor.awardStaked` to work: it transfers the freshly
     *      minted shares to the recipient in the same transaction as the deposit, which reverts
     *      (teller-side) if shares are still locked.
     */
    function shareLockPeriod() external view returns (uint64);

    /// @notice Whether the teller is currently paused.
    function isPaused() external view returns (bool);
}
