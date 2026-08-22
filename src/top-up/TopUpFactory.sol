// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { BeaconFactory, UpgradeableBeacon } from "../beacon-factory/BeaconFactory.sol";
import { ITopUpFactory } from "../interfaces/ITopUpFactory.sol";
import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
import { DelegateCallLib } from "../libraries/DelegateCallLib.sol";
import { TopUp, Constants } from "./TopUp.sol";
import { BridgeAdapterBase } from "./bridge/BridgeAdapterBase.sol";

/**
 * @title TopUpFactory
 * @notice Factory contract for deploying TopUp instances using the beacon proxy pattern
 * @dev Extends BeaconFactory to provide Beacon Proxy deployment functionality
 * @author ether.fi
 */
contract TopUpFactory is BeaconFactory, Constants, ITopUpFactory {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using SafeERC20 for IERC20;

    /**
     * @dev Configuration parameters for supported tokens and their bridge settings
     * @param bridgeAdapter Address of the bridge adapter contract for this token
     * @param recipientOnDestChain Address that will receive tokens on the destination chain
     * @param maxSlippageInBps Maximum allowed slippage in basis points (1 bps = 0.01%)
     * @param additionalData Additional data specific to the bridge adapter
     */
    struct TokenConfig {
        address bridgeAdapter;
        address recipientOnDestChain;
        uint96 maxSlippageInBps;
        bytes additionalData;
    }

    /// @custom:storage-location erc7201:etherfi.storage.TopUpFactory
    struct TopUpFactoryStorage {
        /// @notice Set containing addresses of all deployed TopUp instances
        EnumerableSetLib.AddressSet deployedAddresses;
        /// @notice Mapping of token addresses to their bridge configuration (deprecated, use tokenChainConfig)
        mapping(address token => TokenConfig config) tokenConfig;
        /// @notice Address of the wallet used for emergency fund recovery
        address recoveryWallet;
        /// @notice Mapping of token + destination chain ID to bridge configuration
        mapping(address token => mapping(uint256 chainId => TokenConfig config)) tokenChainConfig;
        /// @notice Set of tokens that have at least one chain configured
        EnumerableSetLib.AddressSet supportedTokens;
        /// @notice Address of the destination-chain `TradingSafeFactory`. Used by
        ///         `redirectDestinationFor` to derive each TopUp's destination address.
        address tradingSafeFactory;
        /// @notice Per-token ERC-4626 vault a redirect must deposit into instead of transferring
        ///         the token itself. Set only for raw Backed xStocks whose trading-catalog form
        ///         is the wrapper; zero (the default, and every other token) means transfer as-is.
        mapping(address token => address wrapper) redirectWrapper;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TopUpFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TopUpFactoryStorageLocation = 0xe4e747da44afe6bc45062fa78d7d038abc167c5a78dee3046108b9cc47b1b100;

    /// @notice Max slippage allowed for bridging
    uint96 public constant MAX_ALLOWED_SLIPPAGE = 200; // 2%

    /// @notice Role identifier for accounts authorized to bridge tokens
    bytes32 public constant TOPUP_FACTORY_BRIDGER_ROLE = keccak256("TOPUP_FACTORY_BRIDGER_ROLE");

    /// @notice Role allowed to drive `redirectToTradingSafe`
    bytes32 public constant TOPUP_FACTORY_REDIRECT_ROLE = keccak256("TOPUP_FACTORY_REDIRECT_ROLE");

    /// @notice Emitted when tokens are bridged to the destination chain
    /// @param token The address of the token being bridged
    /// @param amount The amount of tokens being bridged
    event Bridge(address indexed token, uint256 amount, uint256 indexed destChainId);

    /// @notice Emitted when funds are recovered to the recovery wallet
    /// @param recoveryWallet The address receiving the recovered funds
    /// @param token The token being recovered
    /// @param amount The amount of tokens recovered
    event Recovery(address recoveryWallet, address indexed token, uint256 amount);

    /// @notice Emitted when the recovery wallet address is updated
    /// @param oldRecoveryWallet The previous recovery wallet address
    /// @param newRecoveryWallet The new recovery wallet address
    event RecoveryWalletSet(address oldRecoveryWallet, address newRecoveryWallet);

    /// @notice Emitted when the tokens are configured
    /// @param tokens Array of token addresses
    /// @param config Array of TokenConfig struct
    event TokenConfigSet(address[] tokens, uint256[] chainIds, TokenConfig[] config);

    /// @notice Emitted when tokens are retired from the topup lane — their route for the paired
    ///         chain cleared and the token dropped from the supported set.
    /// @param tokens Tokens retired.
    /// @param chainIds Per-entry destination chain whose route was cleared.
    event TokenConfigRemoved(address[] tokens, uint256[] chainIds);

    /// @notice Emitted when the destination-chain TradingSafeFactory address is updated.
    /// @param oldFactory Previous address (zero on first set).
    /// @param newFactory New address.
    event TradingSafeFactorySet(address oldFactory, address newFactory);

    /// @notice Emitted on a successful `redirectToTradingSafe` invocation. Single canonical
    ///         event for every TopUp → TradingSafe redirect on this chain.
    /// @param topUp The TopUp instance that the funds were redirected from.
    /// @param tradingSafe The destination TradingSafe that received the funds.
    /// @param token ERC20 redirected.
    /// @param amount Amount transferred.
    event RedirectFunds(address indexed topUp, address indexed tradingSafe, address indexed token, uint256 amount);

    /// @notice Emitted when a redirect wrapped a raw stock into its ERC-4626 wrapper on the way
    ///         out. Names the conversion the accompanying `RedirectFunds` can't convey: that one
    ///         reports the wrapper and the shares the TradingSafe received, this one what the
    ///         TopUp actually gave up.
    /// @param topUp The TopUp the underlying was pulled from.
    /// @param wrapper The ERC-4626 vault — the trading-supported token the TradingSafe receives.
    /// @param underlying The raw token that was wrapped.
    /// @param assets Amount of `underlying` deposited.
    /// @param shares Amount of `wrapper` credited to the TradingSafe.
    event WrapOnRedirect(address indexed topUp, address indexed wrapper, address indexed underlying, uint256 assets, uint256 shares);

    /// @notice Emitted when a token's redirect wrapper is configured or cleared.
    /// @param token The token being redirected.
    /// @param oldWrapper Previous vault (zero when the token used to travel as-is).
    /// @param newWrapper New vault, or zero to go back to a plain transfer.
    event RedirectWrapperSet(address indexed token, address oldWrapper, address newWrapper);

    /// @notice Emitted for each token `wrapStocks` converted in place at a TopUp. Distinct from
    ///         `WrapOnRedirect`: nothing left the TopUp here, so there is no accompanying
    ///         `RedirectFunds` — the TopUp simply holds the wrapper instead of the raw stock.
    /// @param topUp The TopUp whose raw stock was wrapped, and the receiver of the shares.
    /// @param wrapper The ERC-4626 vault the stock was deposited into.
    /// @param underlying The raw stock that was wrapped.
    /// @param assets Amount of `underlying` deposited — the TopUp's entire balance of it.
    /// @param shares Amount of `wrapper` the TopUp was credited.
    event WrapStock(address indexed topUp, address indexed wrapper, address indexed underlying, uint256 assets, uint256 shares);

    /// @notice Error thrown when a non-admin tries to deploy a topUp contract
    error OnlyAdmin();
    /// @notice Error thrown when trying to pull funds from an address not registered as deployedAddresses
    error InvalidTopUpAddress();
    /// @notice Error thrown when zero address is provided for a token
    error TokenCannotBeZeroAddress();
    /// @notice Error thrown when attempting to bridge a token without configuration
    error TokenConfigNotSet();
    /// @notice Error thrown when attempting to bridge with zero amount
    error AmountCannotBeZero();
    /// @notice Error thrown when attempting to bridge with insufficient balance
    error InsufficientBalance();
    /// @notice Error thrown when recovery wallet is not set
    error RecoveryWalletNotSet();
    /// @notice Error thrown when attempting to set zero address as recovery wallet
    error RecoveryWalletCannotBeZeroAddress();
    /// @notice Error thrown when attempting to recover token which is a supported asset
    error OnlyUnsupportedTokens();
    /// @notice Reverts when a sweep entry point is handed a token this factory has no topup
    ///         configuration for — the redirect path owns those, not `processTopUp`.
    error OnlySupportedTokens();
    /// @notice Error thrown when redirecting a token that isn't supported for trading.
    error TokenNotTradingSupported();
    /// @notice Error thrown when `redirectToTradingSafe` is called by an account lacking the redirect role.
    error OnlyRedirectRole();
    /// @notice Error thrown when the resolved destination is not a deployed, registered TradingSafe.
    error TradingSafeNotDeployed();
    /// @notice Error thrown when array lengths mismatch
    error ArrayLengthMismatch();
    /// @notice Error thrown when the start index is invalid
    error InvalidStartIndex();
    /// @notice Error thrown when the token config passed is invalid
    error InvalidConfig();
    /// @notice Error thrown when insufficient fee is passed for bridging
    error InsufficientFeePassed();
    /// @notice Error thrown when ETH transfer fails
    error NativeTransferFailed();
    /// @notice Error thrown when chain ID is zero
    error ChainIdCannotBeZero();
    /// @notice Reverts when `setTradingSafeFactory` is called with the zero address.
    error TradingSafeFactoryCannotBeZeroAddress();
    /// @notice Reverts when `redirectDestinationFor` is called before
    ///         `setTradingSafeFactory` has been configured.
    error TradingSafeFactoryNotSet();
    /// @notice Reverts when `setRedirectWrappers` is given a vault that is not an ERC-4626 over
    ///         the very token it is being registered for.
    error InvalidRedirectWrapper();
    /// @notice Reverts when the wrap leg credited the TradingSafe no shares at all.
    error WrapMintedNothing();
    /// @notice Reverts when `wrapStocks` is asked to wrap a token with no registered wrapper —
    ///         there is nothing to deposit into, and silently skipping would hide the missing
    ///         `setRedirectWrappers` entry.
    error RedirectWrapperNotSet();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the TopUpFactory contract
     * @dev Sets up the role registry, admin, and beacon implementation
     * @param _roleRegistry Address of the role registry contract
     * @param _topUpImpl Address of the topUp implementation contract
     */
    function initialize(address _roleRegistry, address _topUpImpl) external initializer {
        __BeaconFactory_initialize(_roleRegistry, _topUpImpl);
    }

    /**
     * @notice Deploys a new TopUp contract instance
     * @param salt The salt value used for deterministic deployment
     */
    function deployTopUpContract(bytes32 salt) external whenNotPaused {
        bytes memory initData = abi.encodeWithSelector(TopUp.initialize.selector, address(this));
        address deployed = _deployBeacon(salt, initData);

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        $.deployedAddresses.add(deployed);
    }

    /**
     * @notice Processes specified tokens from a range of deployed topUp contracts
     * @dev Iterates through deployed topUp contracts starting at index 'start' and calls processTopUp on each
     * @param tokens Array of token addresses to process. Every entry must be topup-supported
     *               (or the native-ETH sentinel); see `_validateSweepTokens`.
     * @param start Starting index in the deployedAddresses array
     * @param n Number of topUp contracts to process
     * @custom:throws OnlySupportedTokens If any token has no topup configuration on this factory
     * @custom:throws If start + n exceeds the number of deployed topUp contracts
     * @custom:throws If any topUp's processTopUp call fails
     */
    function processTopUp(address[] calldata tokens, uint256 start, uint256 n) external {
        _validateSweepTokens(tokens);

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        uint256 length = $.deployedAddresses.length();
        if (start >= length) revert InvalidStartIndex();
        if (start + n > length) n = length - start;

        for (uint256 i = 0; i < n;) {
            TopUp(payable($.deployedAddresses.at(start + i))).processTopUp(tokens);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Processes specified tokens from a given topUp contract
     * @dev Verifies the topUp contract is valid before attempting to pull funds
     * @param tokens Array of token addresses to process. Every entry must be topup-supported
     *               (or the native-ETH sentinel); see `_validateSweepTokens`.
     * @param topUpContracts Array of addresses of the topUp contracts to process
     * @custom:throws OnlySupportedTokens If any token has no topup configuration on this factory
     * @custom:throws InvalidTopUpAddress if the TopUp address is not a deployed TopUp contract
     * @custom:throws If the TopUp contracts's processTopUp call fails
     */
    function processTopUpFromContracts(address[] calldata tokens, address[] calldata topUpContracts) external {
        _validateSweepTokens(tokens);

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        uint256 addrLength = topUpContracts.length;

        for (uint256 i = 0; i < addrLength;) {
            if (!$.deployedAddresses.contains(topUpContracts[i])) revert InvalidTopUpAddress();
            TopUp(payable(topUpContracts[i])).processTopUp(tokens);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Shared guard for both sweep entry points: a sweep may only name tokens this factory
     *      actually bridges. Both entry points are deliberately permissionless — anyone may pay
     *      the gas to move a user's bridging asset along its intended path — but without this
     *      check that openness extends to tokens the sweep was never meant to touch.
     *
     *      A token with no topup configuration reaches a TopUp address only by mistake, and the
     *      redirect path (`redirectToTradingSafe`) owns getting it to the user's TradingSafe.
     *      Naming one here pulls it into this factory instead, where the redirect can no longer
     *      see it: the pending `redirectToTradingSafe` reverts on the drained balance, and because
     *      the batch variant is all-or-nothing one griefed entry fails the whole batch. What is
     *      left is a multisig-gated `recoverFunds` per incident to get the user made
     *      whole off-chain. The range variant walks every deployed TopUp, so one transaction could
     *      do this to every user holding a misrouted stock at once — cheap for the caller, who
     *      gains nothing by it, and expensive for us.
     *
     *      Validated against the token list once rather than per TopUp: the list is the same for
     *      every contract in the sweep, so an n-contract range pays for the check once.
     *
     *      The native-ETH sentinel is allowed without a configuration of its own. `TopUp`
     *      converts it to WETH before transferring, so what arrives here is the configured WETH,
     *      and the sentinel names no ERC20 a redirect could ever be configured for.
     * @param tokens Token list handed to a sweep entry point.
     * @custom:throws OnlySupportedTokens If any entry is neither topup-supported nor the ETH sentinel.
     */
    function _validateSweepTokens(address[] calldata tokens) internal view {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        uint256 len = tokens.length;

        for (uint256 i = 0; i < len;) {
            if (tokens[i] != ETH && !$.supportedTokens.contains(tokens[i])) revert OnlySupportedTokens();
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Sets configuration parameters for multiple tokens
     * @dev Allows admin to configure bridge settings for multiple tokens in a single transaction
     * @param tokens Array of token addresses to configure
     * @param configs Array of TokenConfig structs containing bridge settings for each token
     * @custom:throws ArrayLengthMismatch if tokens and configs arrays have different lengths
     * @custom:throws TokenCannotBeZeroAddress if any token address is zero
     * @custom:throws InvalidConfig if any config has invalid parameters:
     *   - bridgeAdapter is zero address
     *   - recipientOnDestChain is zero address
     *   - maxSlippageInBps exceeds MAX_ALLOWED_SLIPPAGE
     * @custom:emits TokenConfigSet when configs are updated
     */
    function setTokenConfig(address[] calldata tokens, uint256[] calldata chainIds, TokenConfig[] calldata configs) external onlyAdminTimelock {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        uint256 len = tokens.length;
        if (len != configs.length || len != chainIds.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            if (tokens[i] == address(0)) revert TokenCannotBeZeroAddress();
            if (chainIds[i] == 0) revert ChainIdCannotBeZero();
            if (configs[i].bridgeAdapter == address(0) || configs[i].recipientOnDestChain == address(0) || configs[i].maxSlippageInBps > MAX_ALLOWED_SLIPPAGE) revert InvalidConfig();

            $.tokenChainConfig[tokens[i]][chainIds[i]] = configs[i];
            $.supportedTokens.add(tokens[i]);
            unchecked {
                ++i;
            }
        }

        emit TokenConfigSet(tokens, chainIds, configs);
    }

    /**
     * @notice Takes each `tokens[i]` off the topup lane for `chainIds[i]`: clears its bridge
     *         configuration for that destination and drops it from the supported set.
     * @dev Admin-only, and the inverse of `setTokenConfig`, which is otherwise a one-way door —
     *      it only ever adds to `supportedTokens`, and rejects a zeroed config, so before this
     *      there was no way to retire an asset from the lane at all.
     *
     *      Both halves matter and neither is sufficient alone. `bridge` gates on
     *      `tokenChainConfig[token][destChainId].bridgeAdapter`, never on the supported set, so
     *      leaving the config in place would keep the route open to the bridger role; while
     *      `processTopUp`, `recoverFunds`, the redirects and `wrapStocks` all gate on the set, so
     *      leaving the token in it would keep sweeping the asset the config no longer routes.
     *
     *      A token leaves the supported set as soon as one of its routes is removed, because the
     *      set has no per-chain granularity and the chains a token is configured for are not
     *      enumerable on-chain. A token with routes on several destinations must therefore have
     *      all of them passed in — otherwise the leftover routes stay bridgeable while sweeping
     *      stops, which is a half-retired asset. Removing a route that was never configured
     *      reverts rather than passing silently, so a mistyped chain id can't read as a closed
     *      route.
     * @param tokens Tokens to retire.
     * @param chainIds Per-entry destination chain whose route is being cleared.
     * @custom:throws ArrayLengthMismatch If the two arrays don't agree on length.
     * @custom:throws TokenCannotBeZeroAddress If any `tokens[i]` is the zero address.
     * @custom:throws ChainIdCannotBeZero If any `chainIds[i]` is zero.
     * @custom:throws TokenConfigNotSet If any `(tokens[i], chainIds[i])` has no configured route.
     * @custom:emits TokenConfigRemoved
     */
    function removeTokenConfig(address[] calldata tokens, uint256[] calldata chainIds) external onlyAdminTimelock {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        uint256 len = tokens.length;
        if (len != chainIds.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            if (token == address(0)) revert TokenCannotBeZeroAddress();
            if (chainIds[i] == 0) revert ChainIdCannotBeZero();
            if ($.tokenChainConfig[token][chainIds[i]].bridgeAdapter == address(0)) revert TokenConfigNotSet();

            delete $.tokenChainConfig[token][chainIds[i]];
            $.supportedTokens.remove(token);
            unchecked {
                ++i;
            }
        }

        emit TokenConfigRemoved(tokens, chainIds);
    }

    /**
     * @notice Bridges tokens to the destination chain using the configured bridge adapter
     * @dev Uses delegate call to execute the bridge operation through the appropriate adapter
     * @param token The address of the token to bridge
     * @custom:throws TokenCannotBeZeroAddress if token address is zero
     * @custom:throws TokenConfigNotSet if bridge configuration is not set for the token
     * @custom:throws AmountCannotBeZero if amount passed is zero
     * @custom:throws InsufficientBalance if contract has insufficient balance of the specified token
     */
    function bridge(address token, uint256 amount, uint256 destChainId) external payable whenNotPaused onlyRole(TOPUP_FACTORY_BRIDGER_ROLE) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (token == address(0)) revert TokenCannotBeZeroAddress();
        if (destChainId == 0) revert ChainIdCannotBeZero();
        if (amount == 0) revert AmountCannotBeZero();

        TokenConfig storage config = $.tokenChainConfig[token][destChainId];
        if (config.bridgeAdapter == address(0)) revert TokenConfigNotSet();

        uint256 balance = token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        (, uint256 bridgeFee) = getBridgeFee(token, amount, destChainId);
        if (bridgeFee > msg.value) revert InsufficientFeePassed();

        DelegateCallLib.delegateCall(config.bridgeAdapter, abi.encodeWithSelector(BridgeAdapterBase.bridge.selector, token, amount, config.recipientOnDestChain, config.maxSlippageInBps, config.additionalData));

        emit Bridge(token, amount, destChainId);
    }

    /**
     * @notice Recovers ERC20 tokens to the designated recovery wallet
     * @dev Only callable by admin role
     * @param token The address of the token to recover
     * @param amount The amount of tokens to recover
     * @custom:throws OnlyAdmin if caller doesn't have admin role
     * @custom:throws TokenCannotBeZeroAddress if token address is zero
     * @custom:throws OnlyUnsupportedTokens if token is a supported bridge asset
     * @custom:throws RecoveryWalletNotSet if recovery wallet is not configured
     */
    function recoverFunds(address token, uint256 amount) external nonReentrant onlyAdmin {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (token == address(0)) revert TokenCannotBeZeroAddress();
        if ($.supportedTokens.contains(token)) revert OnlyUnsupportedTokens();
        if ($.recoveryWallet == address(0)) revert RecoveryWalletNotSet();

        if (token == ETH) {
            (bool success, ) = payable($.recoveryWallet).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else IERC20(token).safeTransfer($.recoveryWallet, amount);

        emit Recovery($.recoveryWallet, token, amount);
    }

    /**
     * @notice Sets the recovery wallet address for emergency fund recovery
     * @dev Only callable by admin role
     * @param _recoveryWallet The new recovery wallet address
     * @custom:throws OnlyAdmin if caller doesn't have admin role
     * @custom:throws RecoveryWalletCannotBeZeroAddress if provided address is zero
     */
    function setRecoveryWallet(address _recoveryWallet) external onlyAdminTimelock {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (_recoveryWallet == address(0)) revert RecoveryWalletCannotBeZeroAddress();
        emit RecoveryWalletSet($.recoveryWallet, _recoveryWallet);
        $.recoveryWallet = _recoveryWallet;
    }

    /**
     * @notice Sets the destination-chain `TradingSafeFactory` address used by every TopUp
     *         instance when computing the redirect destination.
     * @dev Admin-only. Read by `TopUp.redirectToTradingSafe` via the `tradingSafeFactory()`
     *      view below.
     * @param _tradingSafeFactory Address of the destination-chain TradingSafeFactory.
     * @custom:throws TradingSafeFactoryCannotBeZeroAddress If `_tradingSafeFactory == address(0)`.
     */
    function setTradingSafeFactory(address _tradingSafeFactory) external onlyAdmin {
        if (_tradingSafeFactory == address(0)) revert TradingSafeFactoryCannotBeZeroAddress();
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        emit TradingSafeFactorySet($.tradingSafeFactory, _tradingSafeFactory);
        $.tradingSafeFactory = _tradingSafeFactory;
    }

    /**
     * @notice Returns the destination-chain `TradingSafeFactory` address.
     */
    function tradingSafeFactory() external view returns (address) {
        return _getTopUpFactoryStorage().tradingSafeFactory;
    }

    /**
     * @notice Registers, for each `tokens[i]`, the ERC-4626 vault a redirect must deposit it
     *         into instead of transferring it — or clears that with the zero address.
     * @dev Admin-only. This is the whole of the stock-wrapping feature's configuration: the
     *      tokenized equities a TradingSafe can hold are `WrappedBackedToken` vaults (wTSLAx),
     *      while what a user sends to a TopUp address is the raw Backed xStock underneath
     *      (TSLAx), which is trading-supported in no form of its own and would otherwise be
     *      stranded at the TopUp. Registering TSLAx → wTSLAx makes the existing redirect wrap it
     *      on the way out, with no change to how the backend calls it.
     *
     *      The pairing is verified here rather than trusted: `asset()` must name the very token
     *      being configured, which both proves the vault is the right one and that it is a vault
     *      at all (a non-4626 target reverts the call). That check is what lets
     *      `TopUp.redirectToTradingSafe` approve and call the wrapper without re-validating it.
     *      Curating this per token — rather than probing `asset()` at redirect time — keeps an
     *      arbitrary 4626 that happens to wrap a valuable token from becoming a redirect target.
     * @param tokens Tokens being redirected (the raw stock a TopUp receives).
     * @param wrappers Per-entry ERC-4626 vault over `tokens[i]`, or zero to transfer as-is.
     * @custom:throws ArrayLengthMismatch If the two arrays don't agree on length.
     * @custom:throws TokenCannotBeZeroAddress If any `tokens[i]` is the zero address.
     * @custom:throws InvalidRedirectWrapper If any non-zero `wrappers[i]` is not an ERC-4626
     *                whose `asset()` is `tokens[i]`.
     */
    function setRedirectWrappers(address[] calldata tokens, address[] calldata wrappers) external onlyAdminTimelock {
        uint256 len = tokens.length;
        if (len != wrappers.length) revert ArrayLengthMismatch();

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            address wrapper = wrappers[i];
            if (token == address(0)) revert TokenCannotBeZeroAddress();
            if (wrapper != address(0) && IERC4626(wrapper).asset() != token) revert InvalidRedirectWrapper();

            emit RedirectWrapperSet(token, $.redirectWrapper[token], wrapper);
            $.redirectWrapper[token] = wrapper;
            unchecked { ++i; }
        }
    }

    /**
     * @notice Returns the ERC-4626 vault a redirect of `token` deposits into, or zero when the
     *         token is redirected as-is.
     * @dev Read by every `TopUp` on this factory during `redirectToTradingSafe`.
     */
    function wrapperFor(address token) external view returns (address) {
        return _getTopUpFactoryStorage().redirectWrapper[token];
    }

    /**
     * @notice Returns the destination-chain TradingSafe address that `topUp` redirects to,
     *         derived from the configured `TradingSafeFactory` using the TopUp's own
     *         address as the salt seed. Reverts if `TradingSafeFactory` hasn't been set.
     * @dev Called by `TopUp.redirectToTradingSafe`. Pure factory-side resolution keeps the
     *      TopUp impl stateless.
     * @param topUp The per-user TopUp instance.
     * @custom:throws TradingSafeFactoryNotSet If `setTradingSafeFactory` has not been
     *                called.
     */
    function redirectDestinationFor(address topUp) external view returns (address) {
        address tsFactory = _getTopUpFactoryStorage().tradingSafeFactory;
        if (tsFactory == address(0)) revert TradingSafeFactoryNotSet();
        // The TopUp's own address is the user identity driving the TradingSafe salt — no
        // separate binding needed; off-chain knowledge of "user → TopUp" is enough to know
        // "user → TradingSafe."
        return ITradingSafeFactory(tsFactory).getDeterministicAddress(topUp);
    }

    /**
     * @notice Redirects `amount` of `token` from `topUp` to that user's TradingSafe on the
     *         destination chain. Recovery path for trading-supported, not-topup-supported
     *         tokens that landed at the TopUp address by mistake.
     * @dev Backend-role gated (`TOPUP_FACTORY_REDIRECT_ROLE`). Destination is always the
     *      user's own deployed TradingSafe (derived from the TopUp address); the token must
     *      be NOT topup-supported AND trading-supported, and the destination must be an
     *      already-deployed, registered TradingSafe (never a codeless prediction).
     *
     *      A token with a redirect wrapper configured (`setRedirectWrappers`) is deposited into
     *      that vault instead of transferred, so a raw Backed xStock sitting at a TopUp lands in
     *      the safe as the wrapper its trading catalog actually lists. The trading-supported
     *      check then applies to the wrapper — the form the safe receives — since the raw stock
     *      is trading-supported in no form of its own. Nothing about the call changes: `token`
     *      and `amount` still describe what leaves the TopUp.
     * @param topUp Address of the TopUp instance to redirect from.
     * @param token ERC20 to redirect. Must NOT be topup-supported, and the form it arrives in at
     *              the safe — itself, or its configured wrapper — MUST be trading-supported.
     * @param amount Amount of `token` to transfer.
     * @custom:throws OnlyRedirectRole If caller lacks `TOPUP_FACTORY_REDIRECT_ROLE`.
     * @custom:throws InvalidTopUpAddress If `topUp` was not deployed by this factory.
     * @custom:throws OnlyUnsupportedTokens If `token` has a topup configuration on this
     *                factory (route it through `processTopUp` instead).
     * @custom:throws TradingSafeFactoryNotSet If `setTradingSafeFactory` has not been called.
     * @custom:throws TokenNotTradingSupported If what the safe would receive is not a supported
     *                trading asset.
     * @custom:throws TradingSafeNotDeployed If the resolved TradingSafe isn't deployed/registered.
     * @custom:throws WrapMintedNothing If a wrapped redirect credited the safe no shares.
     */
    function redirectToTradingSafe(address topUp, address token, uint256 amount) external nonReentrant whenNotPaused {
        if (!roleRegistry().hasRole(TOPUP_FACTORY_REDIRECT_ROLE, msg.sender)) revert OnlyRedirectRole();

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        if (!$.deployedAddresses.contains(topUp)) revert InvalidTopUpAddress();
        if ($.supportedTokens.contains(token)) revert OnlyUnsupportedTokens();

        address tsFactory = $.tradingSafeFactory;
        if (tsFactory == address(0)) revert TradingSafeFactoryNotSet();

        address wrapper = $.redirectWrapper[token];
        if (!ITradingSafeFactory(tsFactory).isSupportedToken(wrapper == address(0) ? token : wrapper)) revert TokenNotTradingSupported();

        address tradingSafe = ITradingSafeFactory(tsFactory).getDeterministicAddress(topUp);
        if (!ITradingSafeFactory(tsFactory).isEtherFiSafe(tradingSafe)) revert TradingSafeNotDeployed();

        _executeRedirect(topUp, tradingSafe, token, wrapper, amount);
    }

    /**
     * @notice Batch variant of `redirectToTradingSafe`. Each parallel-array slot identifies
     *         one redirect operation `(topUps[i], tokens[i], amounts[i])`. Any combination
     *         is allowed — same TopUp multiple times for different tokens, multiple TopUps
     *         for the same token, etc.
     * @dev Backend-role gated (same rationale as the single-entry variant). Atomic
     *      all-or-nothing: a revert on any entry rolls back the entire batch. Same
     *      per-entry guards: rejects topup-supported tokens and requires trading-supported.
     *      A token with a configured redirect wrapper wraps on the way out here exactly as it
     *      does in the single-entry variant; both share `_executeRedirect`.
     * @param topUps Per-entry TopUp instance.
     * @param tokens Per-entry ERC20 to redirect. Each must NOT be topup-supported, and the form
     *               it arrives in at the safe — itself, or its configured wrapper — MUST be
     *               trading-supported.
     * @param amounts Per-entry amount of `tokens[i]` to transfer.
     * @custom:throws ArrayLengthMismatch If the three arrays don't agree on length.
     * @custom:throws InvalidTopUpAddress If any `topUps[i]` was not deployed by this factory.
     * @custom:throws OnlyUnsupportedTokens If any `tokens[i]` has a topup configuration on
     *                this factory.
     * @custom:throws TradingSafeFactoryNotSet If `setTradingSafeFactory` has not been called.
     * @custom:throws TokenNotTradingSupported If any `tokens[i]` is not a supported trading asset.
     */
    function batchRedirectToTradingSafe(
        address[] calldata topUps,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external nonReentrant whenNotPaused {
        if (!roleRegistry().hasRole(TOPUP_FACTORY_REDIRECT_ROLE, msg.sender)) revert OnlyRedirectRole();

        uint256 len = topUps.length;
        if (len != tokens.length || len != amounts.length) revert ArrayLengthMismatch();

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        address tsFactory = $.tradingSafeFactory;
        if (tsFactory == address(0)) revert TradingSafeFactoryNotSet();

        for (uint256 i = 0; i < len;) {
            if (!$.deployedAddresses.contains(topUps[i])) revert InvalidTopUpAddress();
            if ($.supportedTokens.contains(tokens[i])) revert OnlyUnsupportedTokens();

            address wrapper = $.redirectWrapper[tokens[i]];
            if (!ITradingSafeFactory(tsFactory).isSupportedToken(wrapper == address(0) ? tokens[i] : wrapper)) revert TokenNotTradingSupported();

            address tradingSafe = ITradingSafeFactory(tsFactory).getDeterministicAddress(topUps[i]);
            if (!ITradingSafeFactory(tsFactory).isEtherFiSafe(tradingSafe)) revert TradingSafeNotDeployed();

            _executeRedirect(topUps[i], tradingSafe, tokens[i], wrapper, amounts[i]);
            unchecked { ++i; }
        }
    }

    /**
     * @dev Shared execution leg for both redirect entry points, reached only once their guards
     *      have passed. The TopUp call is the same one it has always been — `wrapper` is
     *      configuration the TopUp reads back off this factory, not an argument — so this
     *      function's job is only to report what happened.
     *
     *      Unwrapped tokens keep the event they have always emitted. A wrapped one cannot: what
     *      leaves the TopUp is `amount` of the raw stock, while what the safe is credited is the
     *      shares the vault minted for it, and `RedirectFunds` reports the latter so that summing
     *      the event by token still tracks the safe's balance. `WrapOnRedirect` carries the other
     *      half. Shares are read as the safe's balance delta rather than taken from the vault's
     *      return value, so a vault that reports a mint it didn't make can't pass for a redirect.
     * @param topUp TopUp instance to redirect from; already checked as factory-deployed.
     * @param tradingSafe Destination TradingSafe; already checked as deployed and registered.
     * @param token ERC20 leaving the TopUp, in the TopUp's units.
     * @param wrapper Configured vault for `token`, or zero when it moves as-is.
     * @param amount Amount of `token` to move.
     * @custom:throws WrapMintedNothing If the wrap credited the TradingSafe no shares.
     */
    function _executeRedirect(address topUp, address tradingSafe, address token, address wrapper, uint256 amount) internal {
        if (wrapper == address(0)) {
            TopUp(payable(topUp)).redirectToTradingSafe(token, tradingSafe, amount);
            emit RedirectFunds(topUp, tradingSafe, token, amount);
            return;
        }

        uint256 balanceBefore = IERC20(wrapper).balanceOf(tradingSafe);
        TopUp(payable(topUp)).redirectToTradingSafe(token, tradingSafe, amount);
        uint256 shares = IERC20(wrapper).balanceOf(tradingSafe) - balanceBefore;
        if (shares == 0) revert WrapMintedNothing();

        emit WrapOnRedirect(topUp, wrapper, token, amount, shares);
        emit RedirectFunds(topUp, tradingSafe, wrapper, shares);
    }

    /**
     * @notice Wraps every `tokens[i]` a TopUp holds into that token's registered ERC-4626
     *         wrapper, in place — the TopUp itself receives the shares.
     * @dev Permissionless. Nothing leaves the TopUp: a raw Backed xStock (TSLAx) it was sent
     *      becomes the wrapper (wTSLAx) held by the same TopUp, at the same address, so there is
     *      no recipient for a caller to choose and nothing to gain from calling it. What may be
     *      wrapped is fixed by `setRedirectWrappers`, which is admin-curated and validates the
     *      `asset()` pairing, so the deposit target is never an arbitrary address.
     *
     *      The point is the raw stock's dead end: it is trading-supported in no form of its own
     *      and topup-supported in none either, so left as-is it can neither be swept by
     *      `processTopUp` nor redirected. Converting it to the form the catalogs do list hands it
     *      back to whichever rail should carry it — and that rail runs its own support checks, so
     *      this one deliberately asserts nothing about the wrapper beyond the vault minting.
     *
     *      Each entry wraps the TopUp's whole balance, so the caller needs no amounts and the
     *      TopUp is left holding none of the raw stock. A zero balance is skipped rather than
     *      reverted: the caller can pass a user's full stock list without knowing which of them
     *      actually arrived. Shares are read as the TopUp's own balance delta rather than the
     *      vault's return value, the same way `_executeRedirect` does it.
     *
     *      The conversion itself is `TopUp.wrap`, which has no recipient parameter at all: the
     *      shares can only ever be credited to the TopUp doing the wrapping, so no caller of this
     *      function — and no future caller of the TopUp's own entry point — can route them
     *      anywhere. Moving funds off a TopUp remains the redirect path's job alone.
     * @param topUp The TopUp instance holding the raw stocks. Must be factory-deployed.
     * @param tokens Raw stocks to wrap. Each must NOT be topup-supported and MUST have a wrapper
     *               registered via `setRedirectWrappers`.
     * @custom:throws InvalidTopUpAddress If `topUp` was not deployed by this factory.
     * @custom:throws OnlyUnsupportedTokens If any `tokens[i]` has a topup configuration on this
     *                factory (it belongs on the `processTopUp` rail, unwrapped).
     * @custom:throws RedirectWrapperNotSet If any `tokens[i]` has no registered wrapper.
     * @custom:throws WrapMintedNothing If a wrap credited the TopUp no shares.
     */
    function wrapStocks(address topUp, address[] calldata tokens) external nonReentrant whenNotPaused {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        if (!$.deployedAddresses.contains(topUp)) revert InvalidTopUpAddress();

        uint256 len = tokens.length;

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            if ($.supportedTokens.contains(token)) revert OnlyUnsupportedTokens();

            address wrapper = $.redirectWrapper[token];
            if (wrapper == address(0)) revert RedirectWrapperNotSet();

            uint256 amount = IERC20(token).balanceOf(topUp);
            if (amount != 0) {
                uint256 balanceBefore = IERC20(wrapper).balanceOf(topUp);
                TopUp(payable(topUp)).wrap(token, amount);
                uint256 shares = IERC20(wrapper).balanceOf(topUp) - balanceBefore;
                if (shares == 0) revert WrapMintedNothing();

                emit WrapStock(topUp, wrapper, token, amount, shares);
            }

            unchecked { ++i; }
        }
    }

    receive() external payable { }

    /**
     * @notice Gets the bridge fee for a token transfer
     * @dev Queries the bridge adapter for the fee estimation
     * @param token The address of the token to bridge
     * @param amount The amount of the token to bridge
     * @return _token The fee token address
     * @return _amount The fee amount in the _token's decimals
     * @custom:throws TokenCannotBeZeroAddress if token address is zero
     * @custom:throws TokenConfigNotSet if bridge configuration is not set for the token
     * @custom:throws AmountCannotBeZero if contract has no balance of the specified token
     */
    function getBridgeFee(address token, uint256 amount, uint256 destChainId) public view returns (address _token, uint256 _amount) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (token == address(0)) revert TokenCannotBeZeroAddress();
        if (destChainId == 0) revert ChainIdCannotBeZero();
        if (amount == 0) revert AmountCannotBeZero();

        TokenConfig storage config = $.tokenChainConfig[token][destChainId];
        if (config.bridgeAdapter == address(0)) revert TokenConfigNotSet();

        return BridgeAdapterBase(config.bridgeAdapter).getBridgeFee(token, amount, config.recipientOnDestChain, config.maxSlippageInBps, config.additionalData);
    }

    /**
     * @notice Gets deployed TopUp contract addresses
     * @dev Returns an array of TopUp contracts deployed by this factory
     * @param start Starting index in the deployedAddresses array
     * @param n Number of topUp contracts to get
     * @return An array of deployed TopUp contract addresses
     * @custom:throws InvalidStartIndex if start index is invalid
     */
    function getDeployedAddresses(uint256 start, uint256 n) external view returns (address[] memory) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
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
     * @notice Gets the number of contracts deployed
     * @return Number of contracts deployed
     */
    function numContractsDeployed() external view returns (uint256) {
        return _getTopUpFactoryStorage().deployedAddresses.length();
    }

    /**
     * @notice Gets the bridge configuration for a specific token
     * @dev Returns the TokenConfig struct containing bridge settings
     * @param token The address of the token to query
     * @return Configuration parameters for the specified token
     */
    function getTokenConfig(address token, uint256 destChainId) external view returns (TokenConfig memory) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        return $.tokenChainConfig[token][destChainId];
    }

    /**
     * @notice Gets the current recovery wallet address
     * @dev Returns the address where funds can be recovered to
     * @return The configured recovery wallet address
     */
    function getRecoveryWallet() external view returns (address) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        return $.recoveryWallet;
    }

    /**
     * @notice Checks if a given token is supported for bridging
     * @dev Returns whether the token is in the supported tokens set
     * @param token The address of the token to check
     * @return True if the token is supported, false otherwise
     */
    function isTokenSupported(address token) external view returns (bool) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        return $.supportedTokens.contains(token);
    }

    function isTokenSupportedOnChain(address token, uint256 destChainId) external view returns (bool) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        return $.tokenChainConfig[token][destChainId].bridgeAdapter != address(0);
    }

    /**
     * @notice Checks if an address is a deployed TopUp contract
     * @dev Returns whether the address is in the deployed addresses set
     * @param topUpContract The address to check
     * @return True if the address is a deployed TopUp contract, false otherwise
     */
    function isTopUpContract(address topUpContract) external view returns (bool) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        return $.deployedAddresses.contains(topUpContract);
    }

    /**
     * @dev Returns the storage struct for TopUpFactory
     * @return $ Reference to the TopUpFactoryStorage struct
     */
    function _getTopUpFactoryStorage() internal pure returns (TopUpFactoryStorage storage $) {
        assembly {
            $.slot := TopUpFactoryStorageLocation
        }
    }
}
