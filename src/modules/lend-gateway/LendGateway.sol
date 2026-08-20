// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IAaveV4Hub } from "../../interfaces/IAaveV4Hub.sol";
import { IAaveV4Spoke } from "../../interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../interfaces/ICashModule.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ILendGateway } from "../../interfaces/ILendGateway.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { LendCapacityLib } from "./LendCapacityLib.sol";

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
 *      2. Cash side: mutating ops only target factory-registered Cash Safes and only an authorized driver may
 *         call them. Public suppliers use the Aave Spoke directly. The CashModule is always a driver (resolved
 *         live from the data provider); further drivers are added by an ADMIN_TIMELOCK_ROLE holder. A position
 *         manager can move user funds, so who may drive it is the most security-critical surface in this contract.
 *
 *      Invariant: assets only leave a safe's position through this gateway, so every exit lands in the safe
 *      (behind the Cash withdrawal delay) or card settlement (behind spend checks); liquidation at HF < 1 is
 *      the only exception. Two conditions keep it: no position manager other than this gateway is ever
 *      activated on the Spoke (spoke admin controlled), and EtherFiSafe never implements ERC-1271
 *      isValidSignature. Breaking either arms the Spoke's setUserPositionManagersWithSig, letting safe owners
 *      hand the position to another manager by signature alone and withdraw collateral with no delay.
 *
 *      Aave v4 addresses reserves by a uint256 reserveId, not by asset address. The gateway keeps its own
 *      asset -> reserveId registry, each entry validated against the Spoke's getReserve at registration time.
 *
 *      USD reads: ILendGateway's collateralUsd/debtUsd/availableBorrowsUsd remain 6-decimal PriceProvider
 *      values for Cash display only. Capacity is Aave-priced (LendCapacityLib): credit uses borrowCapacity /
 *      rawBorrowCapacity and debit sizing uses the withdrawHeadroom family, all rebuilding Aave's current
 *      oracle-valued collateral and full-RAY debt before quoting.
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

    /// @notice Fast multisig role that registers reserves and tunes risk parameters
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Operating-timelock role that manages the driver allowlist
    bytes32 public constant ADMIN_TIMELOCK_ROLE = keccak256("ADMIN_TIMELOCK_ROLE");

    /// @notice 100% in the ILendGateway ltv scale (100e18 == 100%)
    uint256 internal constant HUNDRED_PERCENT = 100e18;
    /// @notice Converts Aave's BPS collateralFactor to the 100e18 ltv scale (bps * 1e16; 10_000 * 1e16 == 100e18)
    uint256 internal constant BPS_TO_LTV_SCALE = 1e16;
    /// @notice Aave's RAY scale for deficit accounting
    uint256 internal constant RAY = 1e27;
    /// @notice Aave's minimum executable health factor
    uint256 internal constant MIN_HEALTH_FACTOR = 1e18;

    /// @custom:storage-location erc7201:etherfi.storage.LendGateway
    struct LendGatewayStorage {
        /// @notice asset -> Aave reserveId (membership is tracked by `assets`, since reserveId 0 is valid)
        mapping(address asset => uint256 reserveId) reserveId;
        /// @notice The registered assets; membership doubles as the "is registered" check
        EnumerableSetLib.AddressSet assets;
        /// @notice Extra authorized drivers beyond the CashModule (auto-supply / migration paths)
        mapping(address driver => bool authorized) isDriver;
        /// @notice The tokens the card can settle a debit spend in; admin-declared, a subset of `assets`
        EnumerableSetLib.AddressSet spendAssets;
        /// @notice Post-op health-factor floor (WAD) for user-extraction ops (borrow page, withdrawal
        /// sourcing, collateral flag off). 0 = disabled. Spends and repays are deliberately exempt.
        uint256 minHealthFactor;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.LendGateway")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LendGatewayStorageLocation = 0x08cdfbb611f2a1b86b361fad47cf7e3d848e6642121a10c5da4ae64fe25c9800;

    /// @notice Emitted when an asset's reserveId is registered or updated
    event ReserveRegistered(address indexed asset, uint256 indexed reserveId);
    /// @notice Emitted when an asset is de-registered
    event ReserveDeregistered(address indexed asset);
    /// @notice Emitted when a driver is authorized or de-authorized
    event DriverSet(address indexed driver, bool authorized);
    /// @notice Emitted when an asset is added to or removed from the debit-spend set
    event SpendAssetSet(address indexed asset, bool spendable);
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
    /// @notice Emitted when the post-op health-factor floor is updated
    event MinHealthFactorSet(uint256 minHealthFactor);

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
    /// @notice Thrown when changing or removing a reserve that still has outstanding debt or supplied balance
    error ReserveStillInUse();
    /// @notice Thrown when an operation would leave the safe's health factor below the configured floor
    error HealthFactorBelowMinimum();
    /// @notice Thrown when setting a health-factor floor outside [1e18, 2e18] (0 disables)
    error InvalidMinHealthFactor();

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

    /// @dev Reverts unless the caller is the CashModule or an authorized driver.
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
     * @notice Registers or updates the reserveId for an asset, validated against the Spoke
     * @dev Re-registering the same reserve is a no-op. Moving to another reserve requires the old reserve to
     *      have zero aggregate supply and debt so existing positions cannot disappear from gateway accounting.
     * @param asset The underlying asset
     * @param reserveId The Aave reserveId for the asset
     */
    function setReserveId(address asset, uint256 reserveId) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (spoke.getReserve(reserveId).underlying != asset) revert ReserveAssetMismatch();

        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if ($.assets.contains(asset)) {
            uint256 currentReserveId = $.reserveId[asset];
            if (currentReserveId == reserveId) return;
            if (spoke.getReserveTotalDebt(currentReserveId) != 0 || spoke.getReserveSuppliedAssets(currentReserveId) != 0) {
                revert ReserveStillInUse();
            }
        }

        $.assets.add(asset);
        $.reserveId[asset] = reserveId;

        emit ReserveRegistered(asset, reserveId);
    }

    /**
     * @notice De-registers an asset
     * @dev Reverts while the reserve still has outstanding debt or supplied balance. Removing a
     * held asset would drop it from the USD views (debt reads 0, understating debt and inflating
     * borrow headroom) and strand supplied funds behind AssetNotRegistered on the withdraw paths.
     * The gate reads spoke-wide aggregates, which any outside address can hold non-zero forever with a
     * dust self-supply (Spoke.supply is permissionless for self-positions, and a debt-free position can
     * be neither liquidated nor force-withdrawn). A reserve pinned that way stays registered by design:
     * freezing it on the Spoke is the deprecation path (no new supply or borrows, exits stay open, every
     * gateway supply flow skips or tolerates a frozen reserve), so removal is never operationally
     * required and the pin is harmless. See audit L-01.
     * @param asset The asset to remove from the registry
     */
    function removeReserve(address asset) external onlyRole(ADMIN_ROLE) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) revert AssetNotRegistered(asset);

        uint256 reserveId = $.reserveId[asset];
        if (spoke.getReserveTotalDebt(reserveId) != 0 || spoke.getReserveSuppliedAssets(reserveId) != 0) {
            revert ReserveStillInUse();
        }

        $.assets.remove(asset);
        $.spendAssets.remove(asset);
        delete $.reserveId[asset];

        emit ReserveDeregistered(asset);
    }

    /**
     * @notice Sets the post-op health-factor floor for user-extraction operations
     * @dev Applies to the borrow page, withdrawal sourcing from Aave, and turning a collateral flag off —
     *      the ops where a user actively extracts risk headroom. Card spends and repays are deliberately
     *      exempt: settlement obligations must never fail on the floor, and de-risking must always work.
     *      Aave still liquidates at HF < 1e18 regardless; this floor only keeps ether.fi-initiated
     *      extraction from parking a position near that line.
     * @param value The floor in WAD (1e18); 0 disables the check, otherwise bounded to [1e18, 2e18]
     * @custom:throws InvalidMinHealthFactor if value is non-zero and outside [1e18, 2e18]
     */
    function setMinHealthFactor(uint256 value) external onlyRole(ADMIN_ROLE) {
        if (value != 0 && (value < 1e18 || value > 2e18)) revert InvalidMinHealthFactor();
        _getLendGatewayStorage().minHealthFactor = value;
        emit MinHealthFactorSet(value);
    }

    /**
     * @notice Authorizes or de-authorizes a driver (beyond the always-authorized CashModule)
     * @param driver The driver contract (e.g. an auto-supply or migration module)
     * @param authorized True to authorize, false to revoke
     */
    function setDriver(address driver, bool authorized) external onlyRole(ADMIN_TIMELOCK_ROLE) {
        if (driver == address(0)) revert ZeroAddress();
        _getLendGatewayStorage().isDriver[driver] = authorized;
        emit DriverSet(driver, authorized);
    }

    /**
     * @notice Adds or removes an asset from the debit-spend set (the tokens the card can settle in)
     * @dev A spend asset must be a registered reserve, so this reverts with AssetNotRegistered when adding
     *      an unregistered asset. Membership is declared here, not read from Aave's borrowable flag, so a
     *      supply-only reserve can still be a debit-spend token.
     * @param asset The registered asset
     * @param spendable True to add to the set, false to remove
     */
    function setSpendAsset(address asset, bool spendable) external onlyRole(ADMIN_ROLE) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (spendable) {
            if (!$.assets.contains(asset)) revert AssetNotRegistered(asset);
            $.spendAssets.add(asset);
        } else {
            $.spendAssets.remove(asset);
        }
        emit SpendAssetSet(asset, spendable);
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
     * @notice Supplies `amount` of `asset` to Aave on behalf of `safe` and enables it as collateral
     * @dev Driver-only. The Spoke debits the caller, so the gateway first pulls the asset from the safe and
     *      approves the Spoke, then supplies into the safe's position and enables the reserve as collateral.
     *      Both Spoke operations are atomic: if collateral enablement fails, the supply is rolled back.
     *      Rejected if the safe has opted out of lend, or while the gateway is paused.
     * @param safe The safe whose position is credited
     * @param asset The asset being supplied (must be a registered reserve)
     * @param amount The amount to supply
     * @custom:throws OnlyDriver if the caller is not the CashModule or an authorized driver
     * @custom:throws LendOptedOut if the safe has opted out of lend
     * @custom:throws ZeroAmount if amount is zero
     * @custom:throws AssetNotRegistered if asset has no registered reserveId
     */
    function supply(address safe, address asset, uint256 amount) external onlyDriver onlyEtherFiSafe(safe) whenNotPaused nonReentrant whenNotOptedOut(safe) ensuresApproval(safe) {
        if (amount == 0) revert ZeroAmount();
        uint256 reserveId = _reserveIdOf(asset);

        // Spoke pulls the asset from the caller (this gateway), so bring it in from the safe and approve.
        _pullFromSafe(safe, asset, amount);
        IERC20(asset).forceApprove(address(spoke), amount);
        spoke.supply(reserveId, amount, safe);
        spoke.setUsingAsCollateral(reserveId, true, safe);

        emit Supplied(safe, asset, amount);
        emit CollateralUsageSet(safe, asset, true);
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
    function withdraw(address safe, address asset, uint256 amount, address to) external onlyDriver onlyEtherFiSafe(safe) whenNotPaused nonReentrant ensuresApproval(safe) {
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
    function borrow(address safe, address asset, uint256 amount, address to) external onlyDriver onlyEtherFiSafe(safe) whenNotPaused nonReentrant whenNotOptedOut(safe) ensuresApproval(safe) {
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
    function repay(address safe, address asset, uint256 amount) external onlyDriver onlyEtherFiSafe(safe) whenNotPaused nonReentrant ensuresApproval(safe) returns (uint256) {
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
    function setUsingAsCollateral(address safe, address asset, bool useAsCollateral) external onlyDriver onlyEtherFiSafe(safe) whenNotPaused nonReentrant ensuresApproval(safe) {
        // Gate only enabling (a lend op); disabling must stay open so an opted-out safe can drop a residual
        // supplied position from collateral (e.g. one left on Aave after processLendOptOut). It only de-risks.
        if (useAsCollateral && _isLendOptedOut(safe)) revert LendOptedOut();
        spoke.setUsingAsCollateral(_reserveIdOf(asset), useAsCollateral, safe);
        // Dropping a flag with open debt directly cuts the health factor, so it takes the floor; with no
        // debt the health factor is unbounded and the check passes (the opted-out residual-cleanup case)
        if (!useAsCollateral) ensureMinHealthFactor(safe);
        emit CollateralUsageSet(safe, asset, useAsCollateral);
    }

    // ---------------------------------------------------------------------
    // ILendGateway reads
    // ---------------------------------------------------------------------

    /**
     * @notice Whether the safe carries any raw debt on Aave
     * @dev Checks raw per-asset debt, not getAccountData's USD aggregate: debtUsd floors at 6 decimals,
     *      so sub-$0.000001 dust reads as zero there while Aave still enforces it on withdrawals — a
     *      debt-free answer here must mean truly debt-free, or quotes overstate what Aave allows.
     * @param safe The safe to check
     * @return True when any registered asset carries debt for the safe
     */
    function hasDebt(address safe) public view returns (bool) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        uint256 len = $.assets.length();
        for (uint256 i = 0; i < len;) {
            if (spoke.getUserTotalDebt($.reserveId[$.assets.at(i)], safe) != 0) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /**
     * @notice The post-op health-factor floor (WAD) for user-extraction ops; 0 = disabled
     * @return The floor in WAD
     */
    function minHealthFactor() external view returns (uint256) {
        return _getLendGatewayStorage().minHealthFactor;
    }

    /**
     * @notice Reverts when `safe`'s health factor sits below the configured floor
     * @dev The enforcement hook for the extraction paths: called after the borrow-page borrow, after a
     *      withdrawal request pulls from Aave, and after a collateral flag is turned off. A safe with no
     *      debt has an unbounded health factor and always passes. No-op while the floor is disabled.
     * @param safe The safe to check
     * @custom:throws HealthFactorBelowMinimum if the floor is set and the safe's health factor is below it
     */
    function ensureMinHealthFactor(address safe) public view {
        uint256 floor = _getLendGatewayStorage().minHealthFactor;
        if (floor == 0) return;
        if (spoke.getUserAccountData(safe).healthFactor < floor) revert HealthFactorBelowMinimum();
    }

    /**
     * @notice `safe`'s current Aave health factor in WAD (1e18), unbounded when it carries no debt
     * @dev Read straight from the Spoke, like the floor check itself: getAccountData's healthFactor is the
     *      same number but reached through the PriceProvider-derived USD fields, which revert for a supplied
     *      asset Cash cannot price.
     * @param safe The safe to query
     * @return The health factor in WAD
     */
    function healthFactor(address safe) external view returns (uint256) {
        return spoke.getUserAccountData(safe).healthFactor;
    }

    /**
     * @notice Enforces the floor as "no worse off": passes when the position did not degrade, otherwise
     *         requires the end state to hold the configured floor
     * @dev The floor exists to stop ether.fi-initiated operations from parking a position near Aave's
     *      liquidation line, so it has nothing to say about an operation that holds or improves health. A
     *      plain floor check cannot express that: comparing only the end state traps a safe sitting between
     *      Aave's 1.00 bound and the floor, blocking even the de-risking operations that would lift it out.
     *      An operation that degrades health still takes the full floor, so nothing may cross down through it.
     * @param safe The safe to check
     * @param healthFactorBefore The safe's health factor captured before the operation ran
     * @custom:throws HealthFactorBelowMinimum if the operation degraded health and the end state is below the floor
     */
    function ensureMinHealthFactorNotWorsened(address safe, uint256 healthFactorBefore) external view {
        if (spoke.getUserAccountData(safe).healthFactor >= healthFactorBefore) return;
        ensureMinHealthFactor(safe);
    }

    /**
     * @notice Returns `safe`'s Cash-priced position summary (collateral, debt, borrow headroom, health factor)
     * @dev Re-derives the USD fields from PriceProvider for display only; capacity and sizing use the
     *      Aave-priced borrowCapacity and withdrawHeadroom families. healthFactor (WAD) comes directly from Aave.
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
            // Debt rounds UP: flooring lets sub-micro-dollar dust vanish from debtUsd (and inflate
            // availableBorrowsUsd) while Aave still enforces it, so quotes sized on these aggregates
            // would overstate what a withdraw or borrow can actually do
            if (debt != 0) data.debtUsd += _toUsdCeil(asset, debt, priceProvider);

            unchecked {
                ++i;
            }
        }

        // Gross power is reported unclamped alongside the clamped headroom: once debt passes gross power the
        // headroom floors at zero, which cannot distinguish an over-LTV position from one sitting exactly at
        // its limit, and nothing else here recovers the gap.
        data.maxBorrowUsd = maxBorrowUsd;
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
     * @notice Returns the reserve-level Hub liquidity currently available for withdrawals
     * @dev This is not a Safe's withdrawal limit. Returns zero while the reserve is paused or its Hub Spoke is
     *      inactive or halted.
     * @param asset The reserve asset
     * @return The available liquidity in asset units, or 0 if the asset is not registered
     */
    function withdrawalLiquidity(address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return _withdrawalLiquidity($.reserveId[asset]);
    }

    /**
     * @notice Returns the reserve-level Hub liquidity currently available for borrowing
     * @dev This is not a Safe's borrowing limit. Returns zero unless both the reserve and Hub Spoke accept a
     *      borrow. Finite draw-cap usage includes drawn debt, premium, and reported deficit rounded up exactly
     *      as Hub execution does.
     * @param asset The reserve asset
     * @return The borrowable amount in asset units
     */
    function borrowLiquidity(address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;

        uint256 reserveId = $.reserveId[asset];
        if (!_isBorrowable(reserveId)) return 0;

        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(reserveId);
        IAaveV4Hub hub = IAaveV4Hub(reserve.hub);
        IAaveV4Hub.SpokeConfig memory config = hub.getSpokeConfig(reserve.assetId, address(spoke));
        if (!config.active || config.halted) return 0;

        uint256 cash = hub.getAssetLiquidity(reserve.assetId);
        if (config.drawCap == hub.MAX_ALLOWED_SPOKE_CAP()) return cash;

        uint256 capLimit = uint256(config.drawCap) * (10 ** reserve.decimals);
        uint256 owed = hub.getSpokeTotalOwed(reserve.assetId, address(spoke));
        if (owed >= capLimit) return 0;

        uint256 remainingCap = capLimit - owed;
        uint256 deficit = Math.ceilDiv(hub.getSpokeDeficitRay(reserve.assetId, address(spoke)), RAY);
        if (deficit >= remainingCap) return 0;
        remainingCap -= deficit;
        return cash < remainingCap ? cash : remainingCap;
    }

    /**
     * @notice Returns the amount of `asset` the Spoke can currently accept as new supply
     * @dev Zero while the reserve is paused or frozen or its Hub Spoke is inactive or halted (the states
     *      where Aave rejects a supply outright); type(uint256).max when the addCap is the uncapped
     *      sentinel. Finite cap usage counts the spoke's added shares rounded up exactly as Hub execution
     *      does, so filling to this headroom never trips AddCapExceeded.
     * @param asset The reserve asset
     * @return The suppliable amount in asset units, or 0 if the asset is not registered
     */
    function supplyHeadroom(address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;

        uint256 reserveId = $.reserveId[asset];
        IAaveV4Spoke.ReserveConfig memory reserveConfig = spoke.getReserveConfig(reserveId);
        if (reserveConfig.paused || reserveConfig.frozen) return 0;

        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(reserveId);
        IAaveV4Hub hub = IAaveV4Hub(reserve.hub);
        IAaveV4Hub.SpokeConfig memory config = hub.getSpokeConfig(reserve.assetId, address(spoke));
        if (!config.active || config.halted) return 0;
        if (config.addCap == hub.MAX_ALLOWED_SPOKE_CAP()) return type(uint256).max;

        uint256 capLimit = uint256(config.addCap) * (10 ** reserve.decimals);
        uint256 supplied = hub.previewAddByShares(reserve.assetId, spoke.getReserveSuppliedShares(reserveId));
        return supplied >= capLimit ? 0 : capLimit - supplied;
    }

    /**
     * @notice Returns `safe`'s buffered Aave-priced borrowing capacity in units of `asset`
     * @dev The auth quote: capacity that keeps the post-borrow health factor at or above the configured floor
     *      (Aave's 1.00 bound while no floor is set). New auth decisions and getMaxSpendCredit read this so an
     *      approved spend settles with margin. Spend execution reads rawBorrowCapacity instead.
     * @param safe The Safe whose position backs the borrow
     * @param asset The asset to borrow
     * @return The maximum additional borrow in asset units, or 0 if the asset is unregistered
     */
    function borrowCapacity(address safe, address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        uint256 floor = $.minHealthFactor;
        return LendCapacityLib.borrowCapacity(spoke, safe, $.reserveId[asset], floor == 0 ? MIN_HEALTH_FACTOR : floor);
    }

    /**
     * @notice Returns `safe`'s Aave-priced borrowing capacity in units of `asset` at Aave's 1.00 health factor
     * @dev The execution quote: what an already-authorized card spend can still borrow, ignoring the configured
     *      floor. Spend-time resupply gates on this so a spend authorized under the buffered quote always lands.
     * @param safe The Safe whose position backs the borrow
     * @param asset The asset to borrow
     * @return The maximum additional borrow in asset units, or 0 if the asset is unregistered
     */
    function rawBorrowCapacity(address safe, address asset) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return LendCapacityLib.borrowCapacity(spoke, safe, $.reserveId[asset], MIN_HEALTH_FACTOR);
    }

    /**
     * @notice The safe's Aave-priced collateral headroom above the configured health-factor floor
     * @dev The auth quote for collateral withdrawals (debit sizing, max-sourceable), in the weighted
     *      collateral value unit defined by LendCapacityLib.withdrawHeadroom. Execution reads
     *      rawWithdrawHeadroom instead, mirroring the borrowCapacity/rawBorrowCapacity pair.
     * @param safe The Safe whose position is measured
     * @return The headroom in weighted collateral value units
     */
    function withdrawHeadroom(address safe) external view returns (uint256) {
        uint256 floor = _getLendGatewayStorage().minHealthFactor;
        return LendCapacityLib.withdrawHeadroom(spoke, safe, floor == 0 ? MIN_HEALTH_FACTOR : floor);
    }

    /**
     * @notice The safe's Aave-priced collateral headroom above Aave's 1.00 health-factor bound
     * @dev The execution quote: what an already-authorized debit settlement or repay sizing may consume,
     *      ignoring the configured floor.
     * @param safe The Safe whose position is measured
     * @return The headroom in weighted collateral value units
     */
    function rawWithdrawHeadroom(address safe) external view returns (uint256) {
        return LendCapacityLib.withdrawHeadroom(spoke, safe, MIN_HEALTH_FACTOR);
    }

    /**
     * @notice The weighted collateral value the safe's position is short of Aave's 1.00 bound, 0 while healthy
     * @dev The unclamped complement of rawWithdrawHeadroom (audit L-08): the capacity views clamp at zero
     *      once a price move parks the position under 1.00, hiding how deep. Sizing paths that must pass
     *      Aave's whole-position check (credit resupply, the repay-withdraw leg) add this so a pre-existing
     *      deficit is covered up front rather than resurfacing as an opaque Aave revert.
     * @param safe The Safe whose position is measured
     * @return The deficit in weighted collateral value units
     */
    function deficitValue(address safe) external view returns (uint256) {
        return LendCapacityLib.deficitValue(spoke, safe);
    }

    /**
     * @notice Amount of `asset` the safe can withdraw from Aave while consuming at most `headroom`
     * @dev Supply carrying no borrowing power (collateral flag off or zero collateral factor) is fully
     *      withdrawable, matching Aave's own check.
     * @param safe The Safe whose position is measured
     * @param asset The supplied asset
     * @param headroom The weighted collateral value the withdrawal may consume
     * @return The withdrawable amount in asset units, or 0 if the asset is unregistered
     */
    function collateralForHeadroom(address safe, address asset, uint256 headroom) external view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return LendCapacityLib.collateralForHeadroom(spoke, safe, $.reserveId[asset], headroom);
    }

    /**
     * @notice The weighted collateral value withdrawing `amount` of `asset` consumes
     * @param safe The Safe whose position is measured
     * @param asset The supplied asset (must be registered)
     * @param amount The withdrawal in asset units
     * @return The consumed weighted collateral value
     */
    function headroomRemoved(address safe, address asset, uint256 amount) external view returns (uint256) {
        return LendCapacityLib.headroomRemoved(spoke, safe, _reserveIdOf(asset), amount);
    }

    /**
     * @notice The weighted collateral value a borrow of `amount` of `asset` requires at Aave's 1.00 bound
     * @dev The value a repay frees is repayValue, which follows Aave's restore rounding instead.
     * @param asset The borrow asset (must be registered)
     * @param amount The borrow in asset units
     * @return The required weighted collateral value
     */
    function borrowValue(address asset, uint256 amount) external view returns (uint256) {
        return LendCapacityLib.borrowValue(spoke, _reserveIdOf(asset), amount);
    }

    /**
     * @notice The weighted collateral value a repay of `amount` of `asset` frees at Aave's 1.00 bound
     * @dev Exact against Aave's restore share rounding, so repay sizing can credit it as headroom without
     *      overshooting Aave's post-withdraw health check (see LendCapacityLib.repayValue).
     * @param safe The Safe whose debt is repaid
     * @param asset The repaid asset (must be registered)
     * @param amount The repay in asset units
     * @return The freed weighted collateral value
     */
    function repayValue(address safe, address asset, uint256 amount) external view returns (uint256) {
        return LendCapacityLib.repayValue(spoke, safe, _reserveIdOf(asset), amount);
    }

    /**
     * @notice Amount of `asset` to supply so the position gains `value` of weighted collateral value
     * @dev Rounded up. Caller guarantees the reserve's collateral factor is nonzero (see ltv).
     * @param asset The collateral asset (must be registered)
     * @param value The weighted collateral value to gain
     * @return The amount to supply in asset units
     */
    function collateralForValue(address asset, uint256 value) external view returns (uint256) {
        return LendCapacityLib.collateralForValue(spoke, _reserveIdOf(asset), value);
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
    ///      here at auth cannot then fail the Spoke's borrow at spend. Credit membership is Aave's
    ///      borrowable flag by design; only the debit gate (isSpendAsset) reads the admin spend set.
    function isBorrowable(address asset) external view returns (bool) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) return false;
        return _isBorrowable($.reserveId[asset]);
    }

    /// @notice The registered assets whose reserves accept a borrow on the Spoke
    function borrowableAssets() external view returns (address[] memory) {
        return _borrowableAssets();
    }

    /**
     * @notice Whether `asset` is an admin-declared card settlement token
     * @dev Static membership only, declared via setSpendAsset (always a subset of registered reserves), so
     *      "is this a card settlement token" keys on neither Aave's borrowable flag (a supply-only reserve
     *      can be spendable) nor its execution state. Aave's state is deliberately NOT folded in (audit
     *      I-02): a debit spend transfers loose balance and withdraws supplied balance, so a spend funded
     *      entirely from loose balance needs nothing from Aave, and folding a pause in here blocked such
     *      settlements outright — worst for a lend-opted-out safe, which is forced into Debit and holds
     *      everything loose. A pause costs only the supplied leg, which withdrawalLiquidity already reports
     *      as zero, so the sourcing gate declines exactly the spends that truly need the withdraw. New debt
     *      takes the full isBorrowable gate, which reads the pause itself.
     * @param asset The asset to query
     */
    function isSpendAsset(address asset) external view returns (bool) {
        return _getLendGatewayStorage().spendAssets.contains(asset);
    }

    /// @notice The admin-declared card settlement tokens (see isSpendAsset: membership, not Aave state)
    function spendAssets() external view returns (address[] memory) {
        return _getLendGatewayStorage().spendAssets.values();
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

    /// @dev The registered assets whose reserves pass the borrow gate (see _isBorrowable)
    function _borrowableAssets() internal view returns (address[] memory) {
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

    /// @dev The registered reserveId for `asset`, reverting if unregistered
    function _reserveIdOf(address asset) internal view returns (uint256) {
        LendGatewayStorage storage $ = _getLendGatewayStorage();
        if (!$.assets.contains(asset)) revert AssetNotRegistered(asset);
        return $.reserveId[asset];
    }

    /// @dev The shared Hub liquidity currently available to this reserve for withdrawal.
    function _withdrawalLiquidity(uint256 reserveId) internal view returns (uint256) {
        if (spoke.getReserveConfig(reserveId).paused) return 0;

        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(reserveId);
        IAaveV4Hub hub = IAaveV4Hub(reserve.hub);
        IAaveV4Hub.SpokeConfig memory config = hub.getSpokeConfig(reserve.assetId, address(spoke));
        if (!config.active || config.halted) return 0;
        return hub.getAssetLiquidity(reserve.assetId);
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

    /// @dev _toUsd rounding up: used for debt legs, where flooring would understate the obligation
    function _toUsdCeil(address asset, uint256 amount, IPriceProvider priceProvider) internal view returns (uint256) {
        uint256 unit = 10 ** IERC20Metadata(asset).decimals();
        return (amount * priceProvider.price(asset) + unit - 1) / unit;
    }

    /// @dev Returns the ERC-7201 storage struct
    function _getLendGatewayStorage() internal pure returns (LendGatewayStorage storage $) {
        assembly {
            $.slot := LendGatewayStorageLocation
        }
    }
}
