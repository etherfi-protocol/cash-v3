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
     * @notice Supplies `amount` of `asset` to Aave on behalf of `safe`
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
     * @notice Returns `safe`'s Aave position summary
     * @dev Source of truth for CashLens canSpend and EtherFiHook health checks
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
