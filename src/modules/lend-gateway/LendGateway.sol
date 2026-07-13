// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IAaveV4Spoke } from "../../interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../interfaces/ICashModule.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ILendGateway } from "../../interfaces/ILendGateway.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";

/**
 * @title LendGateway
 * @notice A safe's Aave v4 position manager. The gateway is registered on the Spoke by governance
 *         (updatePositionManager) and approved per-safe (setUserPositionManager); once both hold, it can
 *         supply/withdraw/borrow/repay on a safe's behalf without a per-op user signature.
 * @dev Security model — two independent gates must BOTH hold for the gateway to move a safe's funds:
 *      1. Aave side: governance must activate the gateway (updatePositionManager, called on the Spoke, not
 *         here) AND the safe must approve it (setUserPositionManager). If either is missing/revoked, every
 *         Spoke op reverts — so a revoked safe simply can no longer be operated (credit spend / auto-supply
 *         break until re-approved). This is enforced by Aave, not re-implemented here.
 *      2. Cash side: only an authorized driver may call the mutating ops. The CashModule is always a driver
 *         (resolved live from the data provider); further drivers (auto-supply, migration) are added by a
 *         LEND_GATEWAY_ADMIN_ROLE holder. A position manager can move user funds, so who may drive it is the most
 *         security-critical surface in this contract.
 *
 *      Aave v4 addresses reserves by a uint256 reserveId, not by asset address. The gateway keeps its own
 *      asset -> reserveId registry, each entry validated against the Spoke's getReserve at registration time.
 *
 *      USD reads: ILendGateway's collateralUsd/debtUsd/availableBorrowsUsd are 6-decimal USD (PriceProvider
 *      scale). Aave reports position value in opaque "units of Value"/RAY, so the gateway does NOT consume
 *      those; it re-derives USD from ether.fi's PriceProvider over the registered assets (matching CashLens),
 *      applying each reserve's LTV for the borrow headroom, and takes only healthFactor (WAD == 1e18) from Aave.
 *
 *      Per-safe approval needs no user signature: the gateway is a DEFAULT module on every safe, which is the
 *      authorization. Approval is folded into ops (ensuresApproval modifier) — the gateway makes the safe call
 *      setUserPositionManager on the Spoke via execTransactionFromModule (msg.sender == safe). It re-approves
 *      whenever it is not currently an active, approved manager, so a user CANNOT durably turn the position
 *      manager off (any op re-establishes approval). Protocol-wide stop is governance deactivating the manager
 *      on the Spoke, or pausing this gateway — not a per-safe opt-out.
 * @author ether.fi
 */
contract LendGateway is ILendGateway, UpgradeableProxy, ModuleBase {
    using SafeERC20 for IERC20;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @notice The ether.fi-managed Aave v4 Spoke this gateway manages positions on
    IAaveV4Spoke public immutable spoke;

    /// @notice Role that registers reserves and manages the driver allowlist
    bytes32 public constant LEND_GATEWAY_ADMIN_ROLE = keccak256("LEND_GATEWAY_ADMIN_ROLE");

    /// @notice 100% in the ILendGateway ltv scale (100e18 == 100%)
    uint256 internal constant HUNDRED_PERCENT = 100e18;
    /// @notice Converts Aave's BPS collateralFactor to the 100e18 ltv scale (bps * 1e16; 10_000 * 1e16 == 100e18)
    uint256 internal constant BPS_TO_LTV_SCALE = 1e16;

    /// @custom:storage-location erc7201:etherfi.storage.LendGateway
    struct LendGatewayStorage {
        /// @notice asset -> Aave reserveId (membership is tracked by `assets`, since reserveId 0 is valid)
        mapping(address asset => uint256 reserveId) reserveId;
        /// @notice The registered assets; membership doubles as the "is registered" check
        EnumerableSetLib.AddressSet assets;
        /// @notice Extra authorized drivers beyond the CashModule (auto-supply / migration paths)
        mapping(address driver => bool authorized) isDriver;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.LendGateway")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LendGatewayStorageLocation = 0x08cdfbb611f2a1b86b361fad47cf7e3d848e6642121a10c5da4ae64fe25c9800;

    /// @notice Emitted when an asset's reserveId is registered or updated
    event ReserveRegistered(address indexed asset, uint256 indexed reserveId);
    /// @notice Emitted when an asset is de-registered
    event ReserveDeregistered(address indexed asset);
    /// @notice Emitted when a driver is authorized or de-authorized
    event DriverSet(address indexed driver, bool authorized);
    /// @notice Emitted when the gateway (re-)approves itself as `safe`'s position manager (folded into an op)
    event PositionManagerApproved(address indexed safe);
    /// @notice Emitted on a supply on a safe's behalf
    event Supplied(address indexed safe, address indexed asset, uint256 amount);
    /// @notice Emitted on a withdraw on a safe's behalf
    event Withdrawn(address indexed safe, address indexed asset, uint256 amount, address indexed to);
    /// @notice Emitted on a borrow on a safe's behalf
    event Borrowed(address indexed safe, address indexed asset, uint256 amount, address indexed to);
    /// @notice Emitted on a repay on a safe's behalf
    event Repaid(address indexed safe, address indexed asset, uint256 amount);
    /// @notice Emitted when collateral usage is toggled for a safe
    event CollateralUsageSet(address indexed safe, address indexed asset, bool useAsCollateral);

    /// @notice Thrown when the caller is not an authorized driver
    error OnlyDriver();
    /// @notice Thrown when an asset has no registered reserveId
    error AssetNotRegistered(address asset);
    /// @notice Thrown when a reserveId's underlying does not match the asset being registered
    error ReserveAssetMismatch();
    /// @notice Thrown when a zero address is supplied where one is not allowed
    error ZeroAddress();
    /// @notice Thrown when an amount argument is zero
    error ZeroAmount();
    /// @notice Thrown when a lend op is attempted for a safe that has opted out of lend
    error LendOptedOut();
    /// @notice Thrown when de-registering a reserve that still has outstanding debt or supplied balance
    error ReserveStillInUse();

    /**
     * @param _etherFiDataProvider Address of the EtherFiDataProvider
     * @param _spoke Address of the Aave v4 Spoke
     */
    constructor(address _etherFiDataProvider, address _spoke) ModuleBase(_etherFiDataProvider) {
        if (_spoke == address(0)) revert ZeroAddress();
        spoke = IAaveV4Spoke(_spoke);
        _disableInitializers();
    }

    /**
     * @notice Initializes the gateway proxy
     * @param _roleRegistry Address of the role registry
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    // ---------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------

    /// @dev Reverts unless the caller is the CashModule or an authorized driver
    function _onlyDriver() internal view {
        if (msg.sender != etherFiDataProvider.getCashModule() && !_getLendGatewayStorage().isDriver[msg.sender]) revert OnlyDriver();
    }

    modifier onlyDriver() {
        _onlyDriver();
        _;
    }

    /// @dev Reverts if `safe` has opted out of lend. Placed before ensuresApproval so an opted-out safe's
    ///      supply/borrow reverts without re-establishing position-manager approval as a side effect.
    modifier whenNotOptedOut(address safe) {
        if (_isLendOptedOut(safe)) revert LendOptedOut();
        _;
    }

    // ---------------------------------------------------------------------
    // Reserve registry & driver management (governance)
    // ---------------------------------------------------------------------

    /**
     * @notice Registers (or updates) the reserveId for an asset, validated against the Spoke
     * @dev Reverts unless the Spoke's reserve `reserveId` has `underlying == asset`
     * @param asset The underlying asset
     * @param reserveId The Aave reserveId for the asset
     * @dev Warning: do not re-point an asset safes already hold positions under; 
     * the USD views then read the new reserve and miss the old, understating debt and 
     * inflating borrow headroom.
     */
    function setReserveId(address asset, uint256 reserveId) external onlyRole(LEND_GATEWAY_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (spoke.getReserve(reserveId).underlying != asset) revert ReserveAssetMismatch();

        LendGatewayStorage storage $ = _getLendGatewayStorage();
        $.assets.add(asset);
        $.reserveId[asset] = reserveId;

        emit ReserveRegistered(asset, reserveId);
    }

    /**
     * @notice De-registers an asset
     * @dev Reverts while the reserve still has outstanding debt or supplied balance. Removing a
     * held asset would drop it from the USD views (debt reads 0, understating debt and inflating
     * borrow headroom) and strand supplied funds behind AssetNotRegistered on the withdraw paths.
     * Our whitelabel Spoke serves only our safes, so the reserve aggregates gate on our positions.
     * @param asset The asset to remove from the registry
     */
    function removeReserve(address asset) external onlyRole(LEND_GATEWAY_ADMIN_ROLE) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) revert AssetNotRegistered(asset);

        uint256 reserveId = $.reserveId[asset];
        if (spoke.getReserveTotalDebt(reserveId) != 0 || spoke.getReserveSuppliedAssets(reserveId) != 0) {
            revert ReserveStillInUse();
        }

        $.assets.remove(asset);
        delete $.reserveId[asset];

        emit ReserveDeregistered(asset);
    }

    /**
     * @notice Authorizes or de-authorizes a driver (beyond the always-authorized CashModule)
     * @param driver The driver contract (e.g. an auto-supply or migration module)
     * @param authorized True to authorize, false to revoke
     */
    function setDriver(address driver, bool authorized) external onlyRole(LEND_GATEWAY_ADMIN_ROLE) {
        if (driver == address(0)) revert ZeroAddress();
        _getLendGatewayStorage().isDriver[driver] = authorized;
        emit DriverSet(driver, authorized);
    }

    // ---------------------------------------------------------------------
    // Position-manager approval (per-safe, no user signature)
    // ---------------------------------------------------------------------

    /**
     * @dev Ensures the gateway is `safe`'s Aave position manager before an op proceeds. No user signature is
     *      needed: the gateway is a default module on every safe, so it can make the safe call
     *      setUserPositionManager on the Spoke via execTransactionFromModule (msg.sender == safe). It
     *      (re-)approves whenever it is not currently an active, approved manager — so a user CANNOT durably
     *      turn the position manager off: any operation re-establishes approval before acting. When already
     *      approved (the common case) this is just a cheap read, so the overhead is negligible.
     * @param safe The safe whose approval is ensured
     */
    modifier ensuresApproval(address safe) {
        _ensureApproved(safe);
        _;
    }

    function _ensureApproved(address safe) internal {
        if (spoke.isPositionManager(safe, address(this))) return;

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = address(spoke);
        data[0] = abi.encodeWithSelector(IAaveV4Spoke.setUserPositionManager.selector, address(this), true);
        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](1), data);

        emit PositionManagerApproved(safe);
    }

    // ---------------------------------------------------------------------
    // ILendGateway operations (drivers only)
    // ---------------------------------------------------------------------

    /**
     * @notice Supplies `amount` of `asset` to Aave on behalf of `safe`
     * @dev Driver-only. The Spoke debits the caller, so the gateway first pulls the asset from the safe and
     *      approves the Spoke, then supplies into the safe's position. Rejected if the safe has opted out of
     *      lend, or while the gateway is paused.
     * @param safe The safe whose position is credited
     * @param asset The asset being supplied (must be a registered reserve)
     * @param amount The amount to supply
     * @custom:throws OnlyDriver if the caller is not the CashModule or an authorized driver
     * @custom:throws LendOptedOut if the safe has opted out of lend
     * @custom:throws ZeroAmount if amount is zero
     * @custom:throws AssetNotRegistered if asset has no registered reserveId
     */
    function supply(address safe, address asset, uint256 amount) external onlyDriver whenNotPaused nonReentrant whenNotOptedOut(safe) ensuresApproval(safe) {
        if (amount == 0) revert ZeroAmount();
        uint256 reserveId = _reserveIdOf(asset);

        // Spoke pulls the asset from the caller (this gateway), so bring it in from the safe and approve.
        _pullFromSafe(safe, asset, amount);
        IERC20(asset).forceApprove(address(spoke), amount);
        spoke.supply(reserveId, amount, safe);

        emit Supplied(safe, asset, amount);
    }

    /**
     * @notice Withdraws `amount` of `asset` from `safe`'s Aave position to `to`
     * @dev Driver-only. The Spoke sends the underlying to this gateway, which forwards exactly the amount
     *      received to `to`. Intentionally NOT gated by lend being enabled, so an opted-out safe can always
     *      exit its position. Aave reverts the withdraw itself if it would drop the position below its
     *      liquidation threshold.
     * @param safe The safe whose position is debited
     * @param asset The asset being withdrawn (must be a registered reserve)
     * @param amount The amount to withdraw
     * @param to The recipient of the withdrawn asset
     * @custom:throws OnlyDriver if the caller is not the CashModule or an authorized driver
     * @custom:throws ZeroAmount if amount is zero
     * @custom:throws ZeroAddress if to is the zero address
     * @custom:throws AssetNotRegistered if asset has no registered reserveId
     */
    function withdraw(address safe, address asset, uint256 amount, address to) external onlyDriver whenNotPaused nonReentrant ensuresApproval(safe) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 reserveId = _reserveIdOf(asset);

        // Spoke sends the underlying to the caller (this gateway); forward the actual amount received.
        (, uint256 assetsWithdrawn) = spoke.withdraw(reserveId, amount, safe);
        IERC20(asset).safeTransfer(to, assetsWithdrawn);

        emit Withdrawn(safe, asset, assetsWithdrawn, to);
    }

    /**
     * @notice Borrows `amount` of `asset` against `safe`'s position and sends it to `to`
     * @dev Driver-only. The Spoke sends the borrowed underlying to this gateway, which forwards it to `to`.
     *      Rejected if the safe has opted out of lend, or while the gateway is paused. Aave reverts if the
     *      borrow would exceed the position's borrowing power.
     * @param safe The safe whose position takes on the debt
     * @param asset The asset being borrowed (must be a registered reserve)
     * @param amount The amount to borrow
     * @param to The recipient of the borrowed asset
     * @custom:throws OnlyDriver if the caller is not the CashModule or an authorized driver
     * @custom:throws LendOptedOut if the safe has opted out of lend
     * @custom:throws ZeroAmount if amount is zero
     * @custom:throws ZeroAddress if to is the zero address
     * @custom:throws AssetNotRegistered if asset has no registered reserveId
     */
    function borrow(address safe, address asset, uint256 amount, address to) external onlyDriver whenNotPaused nonReentrant whenNotOptedOut(safe) ensuresApproval(safe) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 reserveId = _reserveIdOf(asset);

        // Spoke sends the borrowed underlying to the caller (this gateway); forward it.
        (, uint256 assetsBorrowed) = spoke.borrow(reserveId, amount, safe);
        IERC20(asset).safeTransfer(to, assetsBorrowed);

        emit Borrowed(safe, asset, assetsBorrowed, to);
    }

    /**
     * @notice Repays `amount` of `asset` debt on behalf of `safe`
     * @dev Driver-only. Resolves type(uint256).max to the current debt, pulls that amount from the safe,
     *      approves the Spoke, and repays; any amount the Spoke does not consume is refunded to the safe.
     *      Intentionally NOT gated by lend being enabled, so an opted-out safe can always reduce its debt.
     * @param safe The safe whose debt is repaid
     * @param asset The asset being repaid (must be a registered reserve)
     * @param amount The amount to repay; use type(uint256).max to repay the full debt
     * @return The actual amount repaid
     * @custom:throws OnlyDriver if the caller is not the CashModule or an authorized driver
     * @custom:throws ZeroAmount if the resolved repay amount is zero (e.g. max with no outstanding debt)
     * @custom:throws AssetNotRegistered if asset has no registered reserveId
     */
    function repay(address safe, address asset, uint256 amount) external onlyDriver whenNotPaused nonReentrant ensuresApproval(safe) returns (uint256) {
        uint256 reserveId = _reserveIdOf(asset);

        // type(uint256).max means "repay the full debt"; resolve it to the current debt so we pull the right amount.
        uint256 pull = amount == type(uint256).max ? spoke.getUserTotalDebt(reserveId, safe) : amount;
        if (pull == 0) revert ZeroAmount();

        _pullFromSafe(safe, asset, pull);
        IERC20(asset).forceApprove(address(spoke), pull);
        (, uint256 assetsRepaid) = spoke.repay(reserveId, pull, safe);

        // Refund any dust the Spoke did not consume back to the safe.
        if (assetsRepaid < pull) IERC20(asset).safeTransfer(safe, pull - assetsRepaid);

        emit Repaid(safe, asset, assetsRepaid);
        return assetsRepaid;
    }

    /**
     * @notice Toggles whether `safe`'s supplied `asset` counts as collateral on Aave
     * @dev Driver-only. Enabling collateral is a lend op, rejected if the safe has opted out of lend; disabling
     *      is an exit action (like withdraw/repay) and stays open to opted-out safes so a residual position can
     *      still be cleaned up. Rejected while the gateway is paused.
     * @param safe The safe whose position is updated
     * @param asset The supplied asset (must be a registered reserve)
     * @param useAsCollateral True to use as collateral, false to disable
     * @custom:throws OnlyDriver if the caller is not the CashModule or an authorized driver
     * @custom:throws LendOptedOut if enabling collateral usage for a safe that has opted out of lend
     * @custom:throws AssetNotRegistered if asset has no registered reserveId
     */
    function setUsingAsCollateral(address safe, address asset, bool useAsCollateral) external onlyDriver whenNotPaused nonReentrant ensuresApproval(safe) {
        // Gate only enabling (a lend op); disabling must stay open so an opted-out safe can drop a residual
        // supplied position from collateral (e.g. one left on Aave after processLendOptOut). It only de-risks.
        if (useAsCollateral && _isLendOptedOut(safe)) revert LendOptedOut();
        spoke.setUsingAsCollateral(_reserveIdOf(asset), useAsCollateral, safe);
        emit CollateralUsageSet(safe, asset, useAsCollateral);
    }

    // ---------------------------------------------------------------------
    // ILendGateway reads
    // ---------------------------------------------------------------------

    /**
     * @notice Returns `safe`'s Aave position summary (collateral, debt, borrow headroom, health factor)
     * @dev Re-derives USD from ether.fi's PriceProvider over the registered assets (not from Aave's opaque
     *      value units): sums supplied value into collateralUsd, weights collateral-enabled supply by each
     *      reserve's LTV for the borrow headroom, sums debt into debtUsd, and takes healthFactor (WAD)
     *      directly from Aave. Source of truth for CashLens canSpend and EtherFiHook health checks.
     * @param safe The safe to query
     * @return data The safe's account data (USD fields are 6-decimal; healthFactor is 1e18)
     */
    function getAccountData(address safe) external view returns (AccountData memory data) {
        IPriceProvider priceProvider = IPriceProvider(etherFiDataProvider.getPriceProvider());
        LendGatewayStorage storage $ = _getLendGatewayStorage();

        uint256 maxBorrowUsd;
        uint256 len = $.assets.length();
        for (uint256 i = 0; i < len;) {
            address asset = $.assets.at(i);
            uint256 reserveId = $.reserveId[asset];

            uint256 supplied = spoke.getUserSuppliedAssets(reserveId, safe);
            if (supplied != 0) {
                uint256 suppliedUsd = _toUsd(asset, supplied, priceProvider);
                data.collateralUsd += suppliedUsd;
                // Only supply enabled as collateral contributes borrowing power.
                (bool isCollateral,) = spoke.getUserReserveStatus(reserveId, safe);
                if (isCollateral) maxBorrowUsd += (suppliedUsd * _ltv(reserveId)) / HUNDRED_PERCENT;
            }

            uint256 debt = spoke.getUserTotalDebt(reserveId, safe);
            if (debt != 0) data.debtUsd += _toUsd(asset, debt, priceProvider);

            unchecked {
                ++i;
            }
        }

        data.availableBorrowsUsd = maxBorrowUsd > data.debtUsd ? maxBorrowUsd - data.debtUsd : 0;
        // healthFactor is WAD (1e18) on Aave, matching ILendGateway's 1e18 scale.
        data.healthFactor = spoke.getUserAccountData(safe).healthFactor;
    }

    /**
     * @notice Returns the amount of `asset` that `safe` has supplied to Aave
     * @param safe The safe to query
     * @param asset The supplied asset
     * @return The supplied amount in asset units, or 0 if the asset is not registered
     */
    function suppliedOf(address safe, address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return spoke.getUserSuppliedAssets($.reserveId[asset], safe);
    }

    /**
     * @notice Returns the amount of `asset` debt that `safe` owes Aave
     * @param safe The safe to query
     * @param asset The borrowed asset
     * @return The debt amount in asset units, or 0 if the asset is not registered
     */
    function debtOf(address safe, address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return spoke.getUserTotalDebt($.reserveId[asset], safe);
    }

    /**
     * @notice Returns the withdrawable/borrowable liquidity of `asset`'s reserve (supplied minus borrowed)
     * @param asset The reserve asset
     * @return The available liquidity in asset units, or 0 if the asset is not registered
     */
    function availableCash(address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        uint256 reserveId = $.reserveId[asset];
        uint256 supplied = spoke.getReserveSuppliedAssets(reserveId);
        uint256 debt = spoke.getReserveTotalDebt(reserveId);
        return supplied > debt ? supplied - debt : 0;
    }

    /**
     * @notice Returns the loan-to-value of `asset`'s reserve in the 100e18 = 100% scale (matching DebtManager)
     * @dev Derived from the reserve's current dynamic collateralFactor (BPS), scaled by 1e16.
     * @param asset The reserve asset
     * @return The LTV where 100e18 is 100%, or 0 if the asset is not registered
     */
    function ltv(address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return _ltv($.reserveId[asset]);
    }

    // ---------------------------------------------------------------------
    // Views into config
    // ---------------------------------------------------------------------

    /// @notice The reserveId registered for `asset` (reverts if unregistered)
    function reserveIdOf(address asset) external view returns (uint256) {
        return _reserveIdOf(asset);
    }

    /// @notice Whether `asset` has a registered reserveId
    function isRegistered(address asset) external view returns (bool) {
        return _getLendGatewayStorage().assets.contains(asset);
    }

    /// @notice The list of registered assets
    function registeredAssets() external view returns (address[] memory) {
        return _getLendGatewayStorage().assets.values();
    }

    /// @notice Whether `asset` is registered and its reserve accepts a borrow on the Spoke
    /// @dev Mirrors Aave's borrow gate (borrowable, not frozen, not paused) so an asset that passes
    ///      here at auth cannot then fail the Spoke's borrow at spend.
    function isBorrowable(address asset) external view returns (bool) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return false;
        return _isBorrowable($.reserveId[asset]);
    }

    /// @notice The registered assets whose reserves accept a borrow on the Spoke
    function borrowableAssets() external view returns (address[] memory) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        address[] memory assets = $.assets.values();
        uint256 count = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            if (_isBorrowable($.reserveId[assets[i]])) {
                assets[count] = assets[i];
                unchecked {
                    ++count;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(assets, count)
        }
        return assets;
    }

    /// @notice Whether `account` may drive the gateway (CashModule or an authorized driver)
    function isDriver(address account) external view returns (bool) {
        return account == etherFiDataProvider.getCashModule() || _getLendGatewayStorage().isDriver[account];
    }

    /// @notice Whether `safe` currently approves this gateway as an (active) position manager on the Spoke
    function isApprovedBy(address safe) external view returns (bool) {
        return spoke.isPositionManager(safe, address(this));
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Moves `amount` of `asset` from the safe into this gateway via the safe's module execution
    function _pullFromSafe(address safe, address asset, uint256 amount) internal {
        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = asset;
        data[0] = abi.encodeWithSelector(IERC20.transfer.selector, address(this), amount);
        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](1), data);
    }

    /// @dev Whether `safe` has opted out of lend, per the CashModule (the source of truth for the opt-out)
    function _isLendOptedOut(address safe) internal view returns (bool) {
        return ICashModule(etherFiDataProvider.getCashModule()).isLendOptedOut(safe);
    }

    /// @dev Whether the reserve accepts a borrow on the Spoke: borrowable, not frozen, not paused
    function _isBorrowable(uint256 reserveId) internal view returns (bool) {
        IAaveV4Spoke.ReserveConfig memory config = spoke.getReserveConfig(reserveId);
        return config.borrowable && !config.frozen && !config.paused;
    }

    /// @dev The registered reserveId for `asset`, reverting if unregistered
    function _reserveIdOf(address asset) internal view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) revert AssetNotRegistered(asset);
        return $.reserveId[asset];
    }

    /// @dev The reserve's LTV in the 100e18 scale, from its current dynamic collateralFactor (BPS)
    function _ltv(uint256 reserveId) internal view returns (uint256) {
        uint32 key = spoke.getReserve(reserveId).dynamicConfigKey;
        uint256 collateralFactorBps = spoke.getDynamicReserveConfig(reserveId, key).collateralFactor;
        return collateralFactorBps * BPS_TO_LTV_SCALE;
    }

    /// @dev Converts a token amount to 6-decimal USD via the PriceProvider (matching CashLens)
    function _toUsd(address asset, uint256 amount, IPriceProvider priceProvider) internal view returns (uint256) {
        return (amount * priceProvider.price(asset)) / (10 ** IERC20Metadata(asset).decimals());
    }

    /// @dev Returns the ERC-7201 storage struct
    function _getLendGatewayStorage() internal pure returns (LendGatewayStorage storage $) {
        assembly {
            $.slot := LendGatewayStorageLocation
        }
    }
}
