// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IAaveV4Spoke } from "../../interfaces/IAaveV4Spoke.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IGateway } from "../../interfaces/IGateway.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";

/**
 * @title Gateway
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
 *         GATEWAY_ADMIN_ROLE holder. A position manager can move user funds, so who may drive it is the most
 *         security-critical surface in this contract.
 *
 *      Aave v4 addresses reserves by a uint256 reserveId, not by asset address. The gateway keeps its own
 *      asset -> reserveId registry, each entry validated against the Spoke's getReserve at registration time.
 *
 *      USD reads: IGateway's collateralUsd/debtUsd/availableBorrowsUsd are 6-decimal USD (PriceProvider
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
contract Gateway is IGateway, UpgradeableProxy, ModuleBase {
    using SafeERC20 for IERC20;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @notice The ether.fi-managed Aave v4 Spoke this gateway manages positions on
    IAaveV4Spoke public immutable spoke;

    /// @notice Role that registers reserves and manages the driver allowlist
    bytes32 public constant GATEWAY_ADMIN_ROLE = keccak256("GATEWAY_ADMIN_ROLE");

    /// @notice 100% in the IGateway ltv scale (100e18 == 100%)
    uint256 internal constant HUNDRED_PERCENT = 100e18;
    /// @notice Converts Aave's BPS collateralFactor to the 100e18 ltv scale (bps * 1e16; 10_000 * 1e16 == 100e18)
    uint256 internal constant BPS_TO_LTV_SCALE = 1e16;

    /// @custom:storage-location erc7201:etherfi.storage.Gateway
    struct GatewayStorage {
        /// @notice asset -> Aave reserveId (membership is tracked by `assets`, since reserveId 0 is valid)
        mapping(address asset => uint256 reserveId) reserveId;
        /// @notice The registered assets; membership doubles as the "is registered" check
        EnumerableSetLib.AddressSet assets;
        /// @notice Extra authorized drivers beyond the CashModule (auto-supply / migration paths)
        mapping(address driver => bool authorized) isDriver;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.Gateway")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GatewayStorageLocation = 0xef6b7ff7f22dbe95f109f1722b6c4f5324bd342b000fbc132fbeb4f135815100;

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
        if (msg.sender != etherFiDataProvider.getCashModule() && !_getGatewayStorage().isDriver[msg.sender]) revert OnlyDriver();
    }

    modifier onlyDriver() {
        _onlyDriver();
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
     */
    function setReserveId(address asset, uint256 reserveId) external onlyRole(GATEWAY_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (spoke.getReserve(reserveId).underlying != asset) revert ReserveAssetMismatch();

        GatewayStorage storage $ = _getGatewayStorage();
        $.assets.add(asset);
        $.reserveId[asset] = reserveId;

        emit ReserveRegistered(asset, reserveId);
    }

    /**
     * @notice De-registers an asset
     * @param asset The asset to remove from the registry
     */
    function removeReserve(address asset) external onlyRole(GATEWAY_ADMIN_ROLE) {
        GatewayStorage storage $ = _getGatewayStorage();
        if (!$.assets.contains(asset)) revert AssetNotRegistered(asset);

        $.assets.remove(asset);
        delete $.reserveId[asset];

        emit ReserveDeregistered(asset);
    }

    /**
     * @notice Authorizes or de-authorizes a driver (beyond the always-authorized CashModule)
     * @param driver The driver contract (e.g. an auto-supply or migration module)
     * @param authorized True to authorize, false to revoke
     */
    function setDriver(address driver, bool authorized) external onlyRole(GATEWAY_ADMIN_ROLE) {
        if (driver == address(0)) revert ZeroAddress();
        _getGatewayStorage().isDriver[driver] = authorized;
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
    // IGateway operations (drivers only)
    // ---------------------------------------------------------------------

    /// @inheritdoc IGateway
    function supply(address safe, address asset, uint256 amount) external onlyDriver whenNotPaused nonReentrant ensuresApproval(safe) {
        if (amount == 0) revert ZeroAmount();
        uint256 reserveId = _reserveIdOf(asset);

        // Spoke pulls the asset from the caller (this gateway), so bring it in from the safe and approve.
        _pullFromSafe(safe, asset, amount);
        IERC20(asset).forceApprove(address(spoke), amount);
        spoke.supply(reserveId, amount, safe);

        emit Supplied(safe, asset, amount);
    }

    /// @inheritdoc IGateway
    function withdraw(address safe, address asset, uint256 amount, address to) external onlyDriver whenNotPaused nonReentrant ensuresApproval(safe) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 reserveId = _reserveIdOf(asset);

        // Spoke sends the underlying to the caller (this gateway); forward the actual amount received.
        (, uint256 assetsWithdrawn) = spoke.withdraw(reserveId, amount, safe);
        IERC20(asset).safeTransfer(to, assetsWithdrawn);

        emit Withdrawn(safe, asset, assetsWithdrawn, to);
    }

    /// @inheritdoc IGateway
    function borrow(address safe, address asset, uint256 amount, address to) external onlyDriver whenNotPaused nonReentrant ensuresApproval(safe) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 reserveId = _reserveIdOf(asset);

        // Spoke sends the borrowed underlying to the caller (this gateway); forward it.
        (, uint256 assetsBorrowed) = spoke.borrow(reserveId, amount, safe);
        IERC20(asset).safeTransfer(to, assetsBorrowed);

        emit Borrowed(safe, asset, assetsBorrowed, to);
    }

    /// @inheritdoc IGateway
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

    /// @inheritdoc IGateway
    function setUsingAsCollateral(address safe, address asset, bool useAsCollateral) external onlyDriver whenNotPaused nonReentrant ensuresApproval(safe) {
        spoke.setUsingAsCollateral(_reserveIdOf(asset), useAsCollateral, safe);
        emit CollateralUsageSet(safe, asset, useAsCollateral);
    }

    // ---------------------------------------------------------------------
    // IGateway reads
    // ---------------------------------------------------------------------

    /// @inheritdoc IGateway
    function getAccountData(address safe) external view returns (AccountData memory data) {
        IPriceProvider priceProvider = IPriceProvider(etherFiDataProvider.getPriceProvider());
        GatewayStorage storage $ = _getGatewayStorage();

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
        // healthFactor is WAD (1e18) on Aave, matching IGateway's 1e18 scale.
        data.healthFactor = spoke.getUserAccountData(safe).healthFactor;
    }

    /// @inheritdoc IGateway
    function suppliedOf(address safe, address asset) external view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return spoke.getUserSuppliedAssets($.reserveId[asset], safe);
    }

    /// @inheritdoc IGateway
    function debtOf(address safe, address asset) external view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        return spoke.getUserTotalDebt($.reserveId[asset], safe);
    }

    /// @inheritdoc IGateway
    function availableCash(address asset) external view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
        if (!$.assets.contains(asset)) return 0;
        uint256 reserveId = $.reserveId[asset];
        uint256 supplied = spoke.getReserveSuppliedAssets(reserveId);
        uint256 debt = spoke.getReserveTotalDebt(reserveId);
        return supplied > debt ? supplied - debt : 0;
    }

    /// @inheritdoc IGateway
    function ltv(address asset) external view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
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
        return _getGatewayStorage().assets.contains(asset);
    }

    /// @notice The list of registered assets
    function registeredAssets() external view returns (address[] memory) {
        return _getGatewayStorage().assets.values();
    }

    /// @notice Whether `account` may drive the gateway (CashModule or an authorized driver)
    function isDriver(address account) external view returns (bool) {
        return account == etherFiDataProvider.getCashModule() || _getGatewayStorage().isDriver[account];
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

    /// @dev The registered reserveId for `asset`, reverting if unregistered
    function _reserveIdOf(address asset) internal view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
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
    function _getGatewayStorage() internal pure returns (GatewayStorage storage $) {
        assembly {
            $.slot := GatewayStorageLocation
        }
    }
}
