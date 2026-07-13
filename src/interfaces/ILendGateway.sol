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
     * @notice Returns the withdrawable and borrowable liquidity of `asset`'s reserve
     * @param asset The reserve asset
     * @return The available liquidity, in asset units
     */
    function availableCash(address asset) external view returns (uint256);

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
     * @notice Returns whether `asset` is registered and its Aave reserve allows borrowing
     * @dev The gateway-native replacement for DebtManager's isBorrowToken: the spend, borrow, and repay
     *      paths gate their token on this, so retiring the DebtManager does not change what they accept.
     * @param asset The asset to query
     * @return True if the asset is registered and the reserve's borrowable flag is set
     */
    function isBorrowable(address asset) external view returns (bool);

    /**
     * @notice Returns the registered assets whose Aave reserves allow borrowing
     * @dev The gateway-native replacement for DebtManager's getBorrowTokens (see isBorrowable).
     * @return The borrowable asset addresses
     */
    function borrowableAssets() external view returns (address[] memory);
}
