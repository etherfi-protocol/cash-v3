// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILendGateway
 * @notice Seam between the Cash contracts and the ether.fi-managed Aave v4 instance. The gateway
 *         acts as a safe's Aave position manager, performing supply / withdraw / borrow / repay on
 *         the safe's behalf (a card spend cannot wait for a user signature). Cash-side contracts
 *         (CashModule, CashLens, EtherFiHook) depend only on this interface; both the live gateway
 *         and a MockLendGateway satisfy it, so the two tracks can build in parallel.
 * @dev v0 — expected to change. Locked to just enough surface to unblock both tracks. Borrow and
 *      withdraw take an explicit `to` because Aave pays the caller; the caller forwards atomically.
 * @author ether.fi
 */
interface ILendGateway {
    /// @notice A safe's Aave position summary. USD fields are 6 decimals (matching PriceProvider.DECIMALS); healthFactor is 1e18.
    struct AccountData {
        uint256 collateralUsd;
        uint256 debtUsd;
        // borrowing headroom: collateral weighted by each reserve's LTV, minus debt
        uint256 availableBorrowsUsd;
        uint256 healthFactor;
    }

    /**
     * @notice Supplies `amount` of `asset` to Aave on behalf of `safe` and enables it as collateral
     * @dev Supply and collateral enablement are atomic: either both succeed or neither does.
     * @param safe The safe whose position is credited
     * @param asset The asset being supplied
     * @param amount The amount to supply
     */
    function supply(address safe, address asset, uint256 amount) external;

    /**
     * @notice Withdraws `amount` of `asset` from `safe`'s Aave position to `to`
     * @param safe The safe whose position is debited
     * @param asset The asset being withdrawn
     * @param amount The amount to withdraw
     * @param to The recipient of the withdrawn asset
     */
    function withdraw(address safe, address asset, uint256 amount, address to) external;

    /**
     * @notice Borrows `amount` of `asset` against `safe`'s position and sends it to `to`
     * @param safe The safe whose position takes on the debt
     * @param asset The asset being borrowed
     * @param amount The amount to borrow
     * @param to The recipient of the borrowed asset
     */
    function borrow(address safe, address asset, uint256 amount, address to) external;

    /**
     * @notice Repays `amount` of `asset` debt on behalf of `safe`
     * @param safe The safe whose debt is repaid
     * @param asset The asset being repaid
     * @param amount The amount to repay; use type(uint256).max to repay the full debt
     * @return The actual amount repaid
     */
    function repay(address safe, address asset, uint256 amount) external returns (uint256);

    /**
     * @notice Toggles whether `safe`'s supplied `asset` counts as collateral
     * @param safe The safe whose position is updated
     * @param asset The supplied asset
     * @param useAsCollateral True to use as collateral, false to disable
     */
    function setUsingAsCollateral(address safe, address asset, bool useAsCollateral) external;

    /**
     * @notice Returns `safe`'s Cash-priced position summary
     * @dev Used for display and debit sizing; credit authorization uses borrowCapacity.
     * @param safe The safe to query
     * @return The safe's account data
     */
    function getAccountData(address safe) external view returns (AccountData memory);

    /**
     * @notice Whether the safe carries any raw debt on Aave (raw per-asset reads, immune to the
     *         6-decimal flooring of getAccountData's debtUsd)
     * @param safe The safe to check
     * @return True when any registered asset carries debt for the safe
     */
    function hasDebt(address safe) external view returns (bool);

    /**
     * @notice The post-op health-factor floor (WAD) for user-extraction ops; 0 = disabled
     * @return The floor in WAD
     */
    function minHealthFactor() external view returns (uint256);

    /**
     * @notice Reverts HealthFactorBelowMinimum when the floor is set and `safe`'s health factor is below it
     * @dev Extraction paths (borrow page, withdrawal sourcing, collateral flag off, risk-increasing module
     *      flows) call this post-op; spends and repays are deliberately exempt.
     * @param safe The safe to check
     */
    function ensureMinHealthFactor(address safe) external view;

    /**
     * @notice Sets the post-op health-factor floor
     * @param value The floor in WAD; 0 disables, otherwise bounded to [1e18, 2e18]
     */
    function setMinHealthFactor(uint256 value) external;

    /**
     * @notice Returns the amount of `asset` that `safe` has supplied to Aave
     * @param safe The safe to query
     * @param asset The supplied asset
     * @return The supplied amount, in asset units
     */
    function suppliedOf(address safe, address asset) external view returns (uint256);

    /**
     * @notice Returns the amount of `asset` debt that `safe` owes Aave
     * @param safe The safe to query
     * @param asset The borrowed asset
     * @return The debt amount, in asset units
     */
    function debtOf(address safe, address asset) external view returns (uint256);

    /**
     * @notice Returns the reserve-level Hub liquidity currently available for withdrawals
     * @dev This is not a Safe's withdrawal limit, which also depends on its supply and position health. A
     *      borrow is additionally bounded by the Hub's drawCap, so use borrowLiquidity for the credit side.
     * @param asset The reserve asset
     * @return The available liquidity, in asset units
     */
    function withdrawalLiquidity(address asset) external view returns (uint256);

    /**
     * @notice Returns the reserve-level Hub liquidity currently available for borrowing
     * @dev This is not a Safe's borrowing limit, which also depends on its collateral and position health. It
     *      is the lesser of shared Hub liquidity and remaining drawCap after debt, premium, and deficit, and is
     *      zero unless the reserve and Hub Spoke accept borrowing.
     * @param asset The reserve asset
     * @return The borrowable amount, in asset units
     */
    function borrowLiquidity(address asset) external view returns (uint256);

    /**
     * @notice Returns `safe`'s buffered Aave-priced borrowing capacity in units of `asset`
     * @dev The auth quote: capacity holding the post-borrow health factor at or above the configured floor
     *      (Aave's 1.00 bound while no floor is set). Uses Aave's current oracle, collateral factors, debt
     *      indices, and premium. Capacity rounds down. Excludes Hub liquidity and draw caps (see borrowLiquidity).
     * @param safe The Safe whose position backs the borrow
     * @param asset The asset to borrow
     * @return The maximum additional borrow in asset units
     */
    function borrowCapacity(address safe, address asset) external view returns (uint256);

    /**
     * @notice Returns `safe`'s Aave-priced borrowing capacity in units of `asset` at Aave's 1.00 health factor
     * @dev The execution quote: what an already-authorized card spend can still borrow, ignoring the configured
     *      floor. Spend-time resupply gates on this so a spend authorized under borrowCapacity always lands.
     * @param safe The Safe whose position backs the borrow
     * @param asset The asset to borrow
     * @return The maximum additional borrow in asset units
     */
    function rawBorrowCapacity(address safe, address asset) external view returns (uint256);

    /**
     * @notice Returns `safe`'s Aave-priced collateral headroom above the configured health-factor floor
     * @dev The auth quote for collateral withdrawals, in the weighted collateral value unit
     *      (amount * aavePrice * 10^(18 - decimals) * collateralFactorBps). Execution reads
     *      rawWithdrawHeadroom, mirroring the borrowCapacity/rawBorrowCapacity pair.
     * @param safe The Safe whose position is measured
     * @return The headroom in weighted collateral value units
     */
    function withdrawHeadroom(address safe) external view returns (uint256);

    /**
     * @notice Returns `safe`'s Aave-priced collateral headroom above Aave's 1.00 health-factor bound
     * @dev The execution quote: what an already-authorized debit settlement or repay sizing may consume.
     * @param safe The Safe whose position is measured
     * @return The headroom in weighted collateral value units
     */
    function rawWithdrawHeadroom(address safe) external view returns (uint256);

    /**
     * @notice Amount of `asset` the safe can withdraw from Aave while consuming at most `headroom`
     * @dev Supply carrying no borrowing power (collateral flag off or zero collateral factor) is fully
     *      withdrawable, matching Aave's own check. Rounds down, so withdrawing the quote never breaches
     *      the headroom under Aave's own share rounding.
     * @param safe The Safe whose position is measured
     * @param asset The supplied asset
     * @param headroom The weighted collateral value the withdrawal may consume
     * @return The withdrawable amount in asset units, or 0 if the asset is unregistered
     */
    function collateralForHeadroom(address safe, address asset, uint256 headroom) external view returns (uint256);

    /**
     * @notice The weighted collateral value withdrawing `amount` of `asset` consumes
     * @dev Exact against Aave's own share revaluation, so threading it across tokens never under-counts.
     * @param safe The Safe whose position is measured
     * @param asset The supplied asset (must be registered)
     * @param amount The withdrawal in asset units
     * @return The consumed weighted collateral value
     */
    function headroomRemoved(address safe, address asset, uint256 amount) external view returns (uint256);

    /**
     * @notice The weighted collateral value a borrow of `amount` of `asset` requires at Aave's 1.00 bound
     * @dev The value a repay frees is repayValue, which follows Aave's restore rounding instead.
     * @param asset The borrow asset (must be registered)
     * @param amount The borrow in asset units
     * @return The required weighted collateral value
     */
    function borrowValue(address asset, uint256 amount) external view returns (uint256);

    /**
     * @notice The weighted collateral value a repay of `amount` of `asset` frees at Aave's 1.00 bound
     * @dev Exact against Aave's restore share rounding (premium clears first, drawn shares restore rounded
     *      down), so repay sizing can credit it as headroom without overshooting Aave's post-withdraw
     *      health check.
     * @param safe The Safe whose debt is repaid
     * @param asset The repaid asset (must be registered)
     * @param amount The repay in asset units
     * @return The freed weighted collateral value
     */
    function repayValue(address safe, address asset, uint256 amount) external view returns (uint256);

    /**
     * @notice Amount of `asset` to supply so the position gains `value` of weighted collateral value
     * @dev Rounded up. Caller guarantees the reserve's collateral factor is nonzero (see ltv).
     * @param asset The collateral asset (must be registered)
     * @param value The weighted collateral value to gain
     * @return The amount to supply in asset units
     */
    function collateralForValue(address asset, uint256 value) external view returns (uint256);

    /**
     * @notice Returns the loan-to-value of `asset`'s reserve, in the 100e18 = 100% scale (matching DebtManager's CollateralTokenConfig.ltv)
     * @param asset The reserve asset
     * @return The LTV, where 100e18 is 100%
     */
    function ltv(address asset) external view returns (uint256);

    /**
     * @notice Returns whether `asset` is a registered reserve on the gateway
     * @dev A sandwich re-supplies its output only when the asset is registered; an unregistered output
     *      (a swap into a non-collateral token, an unlisted Liquid receipt) stays loose in the safe.
     * @param asset The asset to query
     * @return True if the asset has a registered reserveId
     */
    function isRegistered(address asset) external view returns (bool);

    /**
     * @notice Returns the assets registered on the gateway (each mapped to an Aave reserveId)
     * @dev The authoritative list of assets a safe can have a position in, keyed on the gateway rather than
     *      DebtManager's collateral list (which can be delisted while an Aave position is still open).
     * @return The registered asset addresses
     */
    function registeredAssets() external view returns (address[] memory);

    /**
     * @notice Returns whether `asset` is registered and its Aave reserve accepts a borrow
     * @dev Mirrors Aave's borrow gate (borrowable, not frozen, not paused). The paths that create new
     *      debt gate on this: the credit auth check, the credit spend, and the signed borrow. Debit
     *      spends gate on isSpendAsset and repay gates on isRegistered, so existing positions survive a
     *      freeze or delisting of new debt.
     * @param asset The asset to query
     * @return True if the asset is registered and the reserve accepts a borrow
     */
    function isBorrowable(address asset) external view returns (bool);

    /**
     * @notice Returns the registered assets whose Aave reserves accept a borrow
     * @dev The gateway-native replacement for DebtManager's getBorrowTokens (see isBorrowable).
     * @return The borrowable asset addresses
     */
    function borrowableAssets() external view returns (address[] memory);

    /**
     * @notice Returns whether `asset` can fund a debit spend
     * @dev An admin-declared spend asset (via setSpendAsset, always a registered reserve) whose reserve is
     *      not paused. Membership is declared, not read from Aave's borrowable flag, so a supply-only
     *      reserve can be spendable. Frozen is tolerated: a debit spend only transfers loose balance and
     *      withdraws supplied balance, both of which Aave allows while frozen. Paused blocks the withdraw
     *      leg, so a paused reserve is not spendable.
     * @param asset The asset to query
     * @return True if the asset can fund a debit spend
     */
    function isSpendAsset(address asset) external view returns (bool);

    /**
     * @notice Returns the spend-set assets that can currently fund a debit spend
     * @dev See isSpendAsset.
     * @return The spendable asset addresses
     */
    function spendAssets() external view returns (address[] memory);
}
