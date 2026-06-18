// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { BeaconFactory } from "../beacon-factory/BeaconFactory.sol";
import { ITopUpFactory } from "../interfaces/ITopUpFactory.sol";
import { ITradingLens } from "../interfaces/ITradingLens.sol";
import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
import { EtherFiSafeCore } from "../safe/EtherFiSafeCore.sol";
import { TradingSafe } from "./TradingSafe.sol";

/**
 * @title TradingSafeFactory
 * @author ether.fi
 * @notice Beacon-factory for the mainnet `TradingSafe`. Each user's TradingSafe address is
 *         derived deterministically from their source-chain (OP) safe address via CREATE3 —
 *         so the destination-chain receiver can pre-compute the address before deployment
 *         and the lazy-deploy service can deploy on first need.
 */
contract TradingSafeFactory is BeaconFactory, ITradingSafeFactory {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.TradingSafeFactory
    struct TradingSafeFactoryStorage {
        /// @notice Set containing addresses of all deployed `TradingSafe` instances.
        EnumerableSetLib.AddressSet deployedAddresses;
        /// @notice Mapping of trading safe address to top up address
        mapping(address tradingSafe => address topUp) topUpAddress;
        /// @notice Address of the `TopUpFactory` whose `isTokenSupported` is the source of
        ///         truth for which assets `redirectToTopUp` may move Safe → TopUp.
        address topUpFactory;
        /// @notice Address of the `TradingLens` whose supported-trading-token set backs
        ///         `isSupportedToken`.
        address tradingLens;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TradingSafeFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TradingSafeFactoryStorageLocation = 0x3c7de012baec722acfa4669d08302c573473ac1dafb576cfe023bafb13cbf900;

    /// @notice Role required to deploy a new `TradingSafe` (held by the BE lazy-deploy
    ///         service or 3CP admin for the misroute path).
    bytes32 public constant TRADING_SAFE_FACTORY_ADMIN_ROLE = keccak256("TRADING_SAFE_FACTORY_ADMIN_ROLE");

    /// @notice Role allowed to drive `redirectToTopUp` (held by the BE redirect service).
    bytes32 public constant TRADING_SAFE_REDIRECT_ROLE = keccak256("TRADING_SAFE_REDIRECT_ROLE");

    /// @notice Reverts when `deployTradingSafe` is called by an account lacking the admin role.
    error OnlyAdmin();
    /// @notice Reverts when `getDeployedAddresses` is called with an out-of-bounds start index.
    error InvalidStartIndex();
    /// @notice Reverts when `getTopUpAddress` is queried for an address this factory
    ///         didn't deploy.
    error InvalidTradingSafe();
    /// @notice Reverts when `redirectToTopUp` is called by an account lacking the redirect role.
    error OnlyRedirectRole();
    /// @notice Reverts when `redirectToTopUp` is called with a zero amount.
    error InvalidAmount();
    /// @notice Reverts when `redirectToTopUp` targets a token that isn't topup-supported.
    error UnsupportedTopUpAsset();
    /// @notice Reverts when `redirectToTopUp` runs before `setTopUpFactory` has been configured.
    error TopUpFactoryNotSet();
    /// @notice Reverts when `setTopUpFactory` is called with the zero address.
    error TopUpFactoryCannotBeZeroAddress();
    /// @notice Reverts when `isSupportedToken` runs before `setTradingLens` has been configured.
    error TradingLensNotSet();
    /// @notice Reverts when `setTradingLens` is called with the zero address.
    error TradingLensCannotBeZeroAddress();

    /// @notice Emitted when a new `TradingSafe` is deployed.
    /// @param tradingSafe The address of the deployed `TradingSafe`.
    /// @param topUp The address of the `TopUp` associated with the `TradingSafe`.
    /// @param owners The owners of the `TradingSafe`.
    /// @param modules The modules enabled on the `TradingSafe`.
    /// @param threshold The threshold of the `TradingSafe`.
    event TradingSafeDeployed(address indexed tradingSafe, address indexed topUp, address[] owners, address[] modules, uint8 threshold);

    /// @notice Emitted when the `TopUpFactory` reference is updated.
    /// @param oldFactory Previous address (zero on first set).
    /// @param newFactory New address.
    event TopUpFactorySet(address oldFactory, address newFactory);

    /// @notice Emitted when the `TradingLens` reference is updated.
    /// @param oldLens Previous address (zero on first set).
    /// @param newLens New address.
    event TradingLensSet(address oldLens, address newLens);

    /// @notice Emitted on a successful `redirectToTopUp` invocation. Single canonical event
    ///         for every TradingSafe → TopUp redirect on this chain.
    /// @param tradingSafe The TradingSafe the funds were redirected from.
    /// @param topUp The destination TopUp address.
    /// @param token ERC20 redirected.
    /// @param amount Amount transferred.
    event RedirectFunds(address indexed tradingSafe, address indexed topUp, address indexed token, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises the factory.
     * @param _roleRegistry Address of the role registry contract.
     * @param _tradingSafeImpl Address of the `TradingSafe` implementation contract used by
     *        the beacon proxy.
     */
    function initialize(address _roleRegistry, address _tradingSafeImpl) external initializer {
        __BeaconFactory_initialize(_roleRegistry, _tradingSafeImpl);
    }

    /**
     * @dev Returns the storage struct for `TradingSafeFactory`.
     * @return $ Reference to the `TradingSafeFactoryStorage` struct.
     */
    function _getTradingSafeFactoryStorage() internal pure returns (TradingSafeFactoryStorage storage $) {
        assembly {
            $.slot := TradingSafeFactoryStorageLocation
        }
    }

    /**
     * @dev Derives the deterministic CREATE3 salt for `sourceSafe`. The salt is namespaced
     *      by the literal string "TradingSafe" so it can't collide with salts from other
     *      factories that also key off `sourceSafe`.
     * @param sourceSafe Source-chain safe address.
     * @return The CREATE3 salt.
     */
    function _saltFor(address sourceSafe) internal pure returns (bytes32) {
        return keccak256(abi.encode("TradingSafe", sourceSafe));
    }

    /**
     * @notice Returns the deterministic deployment address for a `TradingSafe` derived from
     *         `sourceSafe` — usable before the safe is deployed.
     * @param sourceSafe Source-chain (OP) safe address.
     * @return The address at which the `TradingSafe` will be (or has been) deployed.
     */
    function getDeterministicAddress(address sourceSafe) external view returns (address) {
        return BeaconFactory.getDeterministicAddress(_saltFor(sourceSafe));
    }

    /**
     * @notice Deploys a new `TradingSafe` for `sourceSafe`.
     * @dev Only callable by addresses holding `TRADING_SAFE_FACTORY_ADMIN_ROLE`. The deployed
     *      address is deterministic from `sourceSafe`; calling with the same `sourceSafe`
     *      twice will revert at the CREATE3 layer (proxy already deployed).
     * @param sourceSafe Source-chain safe address; drives the deterministic destination address.
     * @param _owners Initial owner set for the TradingSafe.
     * @param _modules Modules to enable at deploy.
     * @param _moduleSetupData Per-module init data; same length as `_modules`.
     * @param _threshold Initial signature threshold.
     * @custom:throws OnlyAdmin if caller lacks the admin role.
     */
    function deployTradingSafe(
        address sourceSafe,
        address[] calldata _owners,
        address[] calldata _modules,
        bytes[] calldata _moduleSetupData,
        uint8 _threshold
    ) external whenNotPaused returns (address) {
        if (!roleRegistry().hasRole(TRADING_SAFE_FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        if (sourceSafe == address(0)) revert InvalidInput();

        TradingSafeFactoryStorage storage $ = _getTradingSafeFactoryStorage();

        bytes32 salt = _saltFor(sourceSafe);
        bytes memory initData = abi.encodeWithSelector(EtherFiSafeCore.initialize.selector, _owners, _modules, _moduleSetupData, _threshold);

        address deterministicAddr = BeaconFactory.getDeterministicAddress(salt);
        $.deployedAddresses.add(deterministicAddr);

        address deployed = _deployBeacon(salt, initData);
        $.topUpAddress[deployed] = sourceSafe;

        emit TradingSafeDeployed(deployed, sourceSafe, _owners, _modules, _threshold);
        return deployed;
    }

    /**
     * @notice Returns a slice of deployed `TradingSafe` addresses.
     * @param start Starting index in the `deployedAddresses` set.
     * @param n Maximum number of addresses to return.
     * @return Array of deployed addresses (length may be less than `n` if near the end).
     * @custom:throws InvalidStartIndex if `start >= length`.
     */
    function getDeployedAddresses(uint256 start, uint256 n) external view returns (address[] memory) {
        TradingSafeFactoryStorage storage $ = _getTradingSafeFactoryStorage();
        uint256 length = $.deployedAddresses.length();
        if (start >= length) revert InvalidStartIndex();
        if (start + n > length) n = length - start;
        address[] memory addresses = new address[](n);

        for (uint256 i = 0; i < n;) {
            addresses[i] = $.deployedAddresses.at(start + i);
            unchecked {
                ++i;
            }
        }
        return addresses;
    }

    /**
     * @notice Returns the `TopUp` address associated with a `TradingSafe`.
     * @param tradingSafe The address of the `TradingSafe`.
     * @return The address of the `TopUp` associated with the `TradingSafe`.
     */
    function getTopUpAddress(address tradingSafe) external view returns (address) {
        TradingSafeFactoryStorage storage $ = _getTradingSafeFactoryStorage();
        if (!$.deployedAddresses.contains(tradingSafe)) revert InvalidTradingSafe();
        return _getTradingSafeFactoryStorage().topUpAddress[tradingSafe];
    }

    /**
     * @notice Sets the `TopUpFactory` whose `isTokenSupported` gates `redirectToTopUp`.
     * @dev Admin-only. Mirrors how `TopUpFactory` holds a mutable `tradingSafeFactory`
     *      reference, so the supported-asset source can change without a beacon upgrade.
     * @param _topUpFactory Address of the `TopUpFactory` on this chain.
     * @custom:throws TopUpFactoryCannotBeZeroAddress If `_topUpFactory == address(0)`.
     */
    function setTopUpFactory(address _topUpFactory) external onlyRoleRegistryOwner {
        if (_topUpFactory == address(0)) revert TopUpFactoryCannotBeZeroAddress();
        TradingSafeFactoryStorage storage $ = _getTradingSafeFactoryStorage();
        emit TopUpFactorySet($.topUpFactory, _topUpFactory);
        $.topUpFactory = _topUpFactory;
    }

    /**
     * @notice Returns the configured `TopUpFactory` address.
     */
    function topUpFactory() external view returns (address) {
        return _getTradingSafeFactoryStorage().topUpFactory;
    }

    /**
     * @notice Sets the `TradingLens` registry backing `isSupportedToken`.
     * @dev Admin-only. The lens owns the supported-trading-token set; the factory exposes it
     *      so cross-chain callers (the TopUp source factory) can gate redirects on it.
     * @param _tradingLens Address of the `TradingLens` on this chain.
     * @custom:throws TradingLensCannotBeZeroAddress If `_tradingLens == address(0)`.
     */
    function setTradingLens(address _tradingLens) external onlyRoleRegistryOwner {
        if (_tradingLens == address(0)) revert TradingLensCannotBeZeroAddress();
        TradingSafeFactoryStorage storage $ = _getTradingSafeFactoryStorage();
        emit TradingLensSet($.tradingLens, _tradingLens);
        $.tradingLens = _tradingLens;
    }

    /**
     * @notice Returns the configured `TradingLens` address.
     */
    function tradingLens() external view returns (address) {
        return _getTradingSafeFactoryStorage().tradingLens;
    }

    /**
     * @notice Returns whether `token` is a supported trading asset, per the configured
     *         `TradingLens` registry.
     * @dev Consumed by the TopUp source factory's `redirectToTradingSafe` to ensure only
     *      trading-supported tokens can be recovered to a TradingSafe.
     * @param token The token to check.
     * @return True if `token` is supported for trading.
     * @custom:throws TradingLensNotSet If `setTradingLens` has not been called.
     */
    function isSupportedToken(address token) external view returns (bool) {
        address lens = _getTradingSafeFactoryStorage().tradingLens;
        if (lens == address(0)) revert TradingLensNotSet();
        return ITradingLens(lens).isSupportedToken(token);
    }

    /**
     * @notice Redirects `amount` of `token` from `tradingSafe` to that safe's TopUp address.
     *         The mirror of `TopUpFactory.redirectToTradingSafe`: moves topup-supported
     *         assets Safe → TopUp.
     * @dev Backend-role gated. The destination is always the safe's own deploy-time-bound
     *      TopUp address, and only topup-supported tokens are allowed — so a compromised
     *      role can only move supported funds to *that user's own* TopUp, never elsewhere.
     *      The actual transfer is executed by `TradingSafe.redirectToTopUp` (callable only
     *      by this factory); this function carries the auth + validation + the single event.
     * @param tradingSafe TradingSafe to redirect from. Must be deployed by this factory.
     * @param token ERC20 to redirect. Must be a topup-supported token.
     * @param amount Amount to transfer.
     * @custom:throws OnlyRedirectRole If caller lacks `TRADING_SAFE_REDIRECT_ROLE`.
     * @custom:throws InvalidAmount If `amount == 0`.
     * @custom:throws InvalidTradingSafe If `tradingSafe` was not deployed by this factory.
     * @custom:throws TopUpFactoryNotSet If `setTopUpFactory` has not been called.
     * @custom:throws UnsupportedTopUpAsset If `token` is not topup-supported.
     */
    function redirectToTopUp(address tradingSafe, address token, uint256 amount) external nonReentrant whenNotPaused {
        if (!roleRegistry().hasRole(TRADING_SAFE_REDIRECT_ROLE, msg.sender)) revert OnlyRedirectRole();
        if (amount == 0) revert InvalidAmount();

        TradingSafeFactoryStorage storage $ = _getTradingSafeFactoryStorage();
        if (!$.deployedAddresses.contains(tradingSafe)) revert InvalidTradingSafe();

        address _topUpFactory = $.topUpFactory;
        if (_topUpFactory == address(0)) revert TopUpFactoryNotSet();
        if (!ITopUpFactory(_topUpFactory).isTokenSupported(token)) revert UnsupportedTopUpAsset();

        address topUp = $.topUpAddress[tradingSafe];
        TradingSafe(payable(tradingSafe)).redirectToTopUp(token, topUp, amount);
        emit RedirectFunds(tradingSafe, topUp, token, amount);
    }

    /**
     * @notice Returns the number of `TradingSafe`s deployed by this factory.
     * @return Number of deployed instances.
     */
    function numContractsDeployed() external view returns (uint256) {
        return _getTradingSafeFactoryStorage().deployedAddresses.length();
    }

    /**
     * @notice Checks whether `safeAddr` was deployed by this factory.
     * @dev Named `isEtherFiSafe` (not `isTradingSafe`) so this factory satisfies the
     *      `IEtherFiSafeFactory.isEtherFiSafe(address)` selector that the destination-chain
     *      `EtherFiDataProvider` delegates to. On mainnet, the only EtherFiSafes are
     *      TradingSafes.
     * @param safeAddr The address to check.
     * @return True if the address is a known TradingSafe deployed by this factory.
     */
    function isEtherFiSafe(address safeAddr) external view returns (bool) {
        return _getTradingSafeFactoryStorage().deployedAddresses.contains(safeAddr);
    }
}
