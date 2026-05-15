// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { Constants } from "../utils/Constants.sol";

/**
 * @title TradingLens
 * @author ether.fi
 * @notice contract combining the trading-account supported-token registry
 *         and the per-safe balance + price aggregation 
 */
contract TradingLens is UpgradeableProxy, Constants {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /**
     * @notice Per-token snapshot returned by `getSafeData`.
     * @param token Token contract address.
     * @param balance Raw token balance held by the safe (in the token's native decimals).
     * @param decimals Token decimals, read from `IERC20Metadata.decimals`.
     * @param priceUsd Price returned by the configured `PriceProvider`; same decimal
     *        precision the price provider exposes via `decimals()`. 
     * @param valueUsd Position value in the same decimal precision as `priceUsd`. Computed
     *        as `balance * priceUsd / 10 ** decimals`. 
     */
    struct TokenInfo {
        address token;
        uint256 balance;
        uint8 decimals;
        uint256 priceUsd;
        uint256 valueUsd;
    }

    /// @notice Role allowed to add / remove supported trading tokens.
    bytes32 public constant TRADING_LENS_ADMIN_ROLE = keccak256("TRADING_LENS_ADMIN_ROLE");

    /// @notice Price source for supported tokens.
    IPriceProvider public immutable priceProvider;

    /// @custom:storage-location erc7201:etherfi.storage.TradingLens
    struct TradingLensStorage {
        /// @notice Set of supported trading-account tokens.
        EnumerableSetLib.AddressSet supportedTokens;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TradingLens")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TradingLensStorageLocation = 0x7a3d2e9b6d3e7a5b4c2f9e1a6b8c3d5e7f9a1b3c5d7e9f1a3b5c7d9e1f3a5b00;

    /// @notice Emitted when a token is added to the supported-token set.
    /// @param token The token contract address.
    event SupportedTokenAdded(address indexed token);

    /// @notice Emitted when a token is removed from the supported-token set.
    /// @param token The token contract address.
    event SupportedTokenRemoved(address indexed token);

    /// @notice Reverts when the caller doesn't hold `TRADING_LENS_ADMIN_ROLE`.
    error OnlyAdmin();

    /// @notice Reverts when a zero-address token is passed to `addSupportedToken`.
    error InvalidToken();

    /// @notice Reverts when `addSupportedToken` is called for a token that's already supported.
    /// @param token The token already in the set.
    error TokenAlreadySupported(address token);

    /// @notice Reverts when `removeSupportedToken` is called for a token that isn't supported.
    /// @param token The token not present in the set.
    error TokenNotSupported(address token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _priceProvider) {
        priceProvider = IPriceProvider(_priceProvider);
        _disableInitializers();
    }

    /**
     * @notice Initialises the lens proxy.
     * @param _roleRegistry Role registry used for admin and upgrade authorisation.
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    // ------------------------------------------------------------------
    // Admin surface
    // ------------------------------------------------------------------

    /**
     * @notice Adds `token` to the supported-trading-token set. Idempotent across deploys —
     *         reverts if the token is already present (callers don't want silent no-ops).
     * @param token The token contract to support.
     * @custom:throws OnlyAdmin If caller lacks `TRADING_LENS_ADMIN_ROLE`.
     * @custom:throws InvalidToken If `token == address(0)`.
     * @custom:throws TokenAlreadySupported If `token` is already in the set.
     */
    function addSupportedToken(address token) external {
        if (!roleRegistry().hasRole(TRADING_LENS_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        if (token == address(0)) revert InvalidToken();

        if (!_getTradingLensStorage().supportedTokens.add(token)) revert TokenAlreadySupported(token);
        emit SupportedTokenAdded(token);
    }

    /**
     * @notice Removes `token` from the supported-trading-token set.
     * @param token The token contract to drop.
     * @custom:throws OnlyAdmin If caller lacks `TRADING_LENS_ADMIN_ROLE`.
     * @custom:throws TokenNotSupported If `token` isn't in the set.
     */
    function removeSupportedToken(address token) external {
        if (!roleRegistry().hasRole(TRADING_LENS_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();

        if (!_getTradingLensStorage().supportedTokens.remove(token)) revert TokenNotSupported(token);
        emit SupportedTokenRemoved(token);
    }

    // ------------------------------------------------------------------
    // Read surface
    // ------------------------------------------------------------------

    /// @notice Returns whether `token` is in the supported-trading-token set.
    function isSupportedToken(address token) external view returns (bool) {
        return _getTradingLensStorage().supportedTokens.contains(token);
    }

    /**
     * @notice Returns the full list of currently supported trading tokens.
     * @dev Order matches `EnumerableSetLib` iteration semantics (insertion order modified
     *      by swap-and-pop on removal).
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return _getTradingLensStorage().supportedTokens.values();
    }

    /**
     * @notice Returns per-token balance + price snapshots for `safe` across every supported
     *         trading token, plus the summed USD value across all entries.
     * @dev One call powers the trading dashboard (header total + rows). Bad oracle on a
     *      single token contributes zero to its own row and the total — never reverts.
     * @param safe Address of the safe to inspect.
     * @return tokens One `TokenInfo` per supported token.
     * @return totalValueUsd Sum of `tokens[i].valueUsd`.
     */
    function getSafeData(address safe) external view returns (TokenInfo[] memory tokens, uint256 totalValueUsd) {
        address[] memory supported = _getTradingLensStorage().supportedTokens.values();
        return _getSafeData(safe, supported);
    }

    /**
     * @notice Returns per-token snapshots for `safe` over a caller-specified `requestedTokens`
     *         list. Useful for ad-hoc queries or when the FE wants ordering / filtering not
     *         provided by the canonical supported set.
     * @dev Tokens here are NOT validated against the supported set; the caller takes
     *      responsibility for what they ask about. Bad oracle on any token contributes zero
     *      to its own row and the total — never reverts.
     * @param safe Address of the safe to inspect.
     * @param requestedTokens Tokens to query.
     * @return tokens Parallel array of `TokenInfo`, same length and order as `requestedTokens`.
     * @return totalValueUsd Sum of `tokens[i].valueUsd`.
     */
    function getSafeData(address safe, address[] calldata requestedTokens) external view returns (TokenInfo[] memory tokens, uint256 totalValueUsd) {
        return _getSafeData(safe, requestedTokens);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _getSafeData(address safe, address[] memory tokenList) internal view returns (TokenInfo[] memory tokens, uint256 totalValueUsd) {
        uint256 len = tokenList.length;
        tokens = new TokenInfo[](len);
        for (uint256 i = 0; i < len; ) {
            tokens[i] = _buildTokenInfo(safe, tokenList[i]);
            totalValueUsd += tokens[i].valueUsd;
            unchecked { ++i; }
        }
    }

    /**
     * @dev Builds one snapshot row. Catches reverts in both the price call and the decimals
     *      call so a bad ERC20 or stale oracle on one token doesn't poison the batch.
     * @param safe The safe whose balance is being read.
     * @param token The token to snapshot.
     * @return info Populated `TokenInfo`; `priceUsd`/`valueUsd` are zero on price failure.
     */
    function _buildTokenInfo(address safe, address token) internal view returns (TokenInfo memory info) {
        info.token = token;

        if (token == ETH) {
            info.balance = safe.balance;
            info.decimals = 18;
        } else { 
            info.balance = IERC20(token).balanceOf(safe);
            info.decimals = _safeTokenDecimals(token);
        }

        try priceProvider.price(token) returns (uint256 p) {
            info.priceUsd = p;
            info.valueUsd = info.balance * p / 10 ** info.decimals;
        } catch {
            // Leave priceUsd / valueUsd at zero
        }
    }

    /**
     * @dev Reads `IERC20Metadata.decimals` defensively. Tokens that don't implement
     *      `decimals()` (rare) fall back to 18, which matches OZ's `ERC20` default.
     */
    function _safeTokenDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _getTradingLensStorage() internal pure returns (TradingLensStorage storage $) {
        assembly {
            $.slot := TradingLensStorageLocation
        }
    }
}
