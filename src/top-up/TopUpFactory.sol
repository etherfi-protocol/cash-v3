// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
     * @param tokens Array of token addresses to process
     * @param start Starting index in the deployedAddresses array
     * @param n Number of topUp contracts to process
     * @custom:throws If start + n exceeds the number of deployed topUp contracts
     * @custom:throws If any topUp's processTopUp call fails
     */
    function processTopUp(address[] calldata tokens, uint256 start, uint256 n) external {
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
     * @param tokens Array of token addresses to process
     * @param topUpContracts Array of addresses of the topUp contracts to process
     * @custom:throws InvalidTopUpAddress if the TopUp address is not a deployed TopUp contract
     * @custom:throws If the TopUp contracts's processTopUp call fails
     */
    function processTopUpFromContracts(address[] calldata tokens, address[] calldata topUpContracts) external {
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
    function setTokenConfig(address[] calldata tokens, uint256[] calldata chainIds, TokenConfig[] calldata configs) external onlyRoleRegistryOwner {
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
    function recoverFunds(address token, uint256 amount) external nonReentrant onlyRoleRegistryOwner {
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
    function setRecoveryWallet(address _recoveryWallet) external onlyRoleRegistryOwner {
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
    function setTradingSafeFactory(address _tradingSafeFactory) external onlyRoleRegistryOwner {
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
     * @param topUp Address of the TopUp instance to redirect from.
     * @param token ERC20 to redirect. Must NOT be topup-supported and MUST be trading-supported.
     * @param amount Amount to transfer.
     * @custom:throws OnlyRedirectRole If caller lacks `TOPUP_FACTORY_REDIRECT_ROLE`.
     * @custom:throws InvalidTopUpAddress If `topUp` was not deployed by this factory.
     * @custom:throws OnlyUnsupportedTokens If `token` has a topup configuration on this
     *                factory (route it through `processTopUp` instead).
     * @custom:throws TradingSafeFactoryNotSet If `setTradingSafeFactory` has not been called.
     * @custom:throws TokenNotTradingSupported If `token` is not a supported trading asset.
     * @custom:throws TradingSafeNotDeployed If the resolved TradingSafe isn't deployed/registered.
     */
    function redirectToTradingSafe(address topUp, address token, uint256 amount) external nonReentrant whenNotPaused {
        if (!roleRegistry().hasRole(TOPUP_FACTORY_REDIRECT_ROLE, msg.sender)) revert OnlyRedirectRole();

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        if (!$.deployedAddresses.contains(topUp)) revert InvalidTopUpAddress();
        if ($.supportedTokens.contains(token)) revert OnlyUnsupportedTokens();

        address tsFactory = $.tradingSafeFactory;
        if (tsFactory == address(0)) revert TradingSafeFactoryNotSet();
        if (!ITradingSafeFactory(tsFactory).isSupportedToken(token)) revert TokenNotTradingSupported();

        address tradingSafe = ITradingSafeFactory(tsFactory).getDeterministicAddress(topUp);
        // Only route to an already-deployed, registered TradingSafe — never to a codeless
        // CREATE3 prediction. Also closes the co-location invariant: a misconfigured
        // tradingSafeFactory won't have this safe registered.
        if (!ITradingSafeFactory(tsFactory).isEtherFiSafe(tradingSafe)) revert TradingSafeNotDeployed();

        TopUp(payable(topUp)).redirectToTradingSafe(token, tradingSafe, amount);
        emit RedirectFunds(topUp, tradingSafe, token, amount);
    }

    /**
     * @notice Batch variant of `redirectToTradingSafe`. Each parallel-array slot identifies
     *         one redirect operation `(topUps[i], tokens[i], amounts[i])`. Any combination
     *         is allowed — same TopUp multiple times for different tokens, multiple TopUps
     *         for the same token, etc.
     * @dev Backend-role gated (same rationale as the single-entry variant). Atomic
     *      all-or-nothing: a revert on any entry rolls back the entire batch. Same
     *      per-entry guards: rejects topup-supported tokens and requires trading-supported.
     * @param topUps Per-entry TopUp instance.
     * @param tokens Per-entry ERC20 to redirect. Each must NOT be topup-supported and MUST be
     *               trading-supported.
     * @param amounts Per-entry amount to transfer.
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
            if (!ITradingSafeFactory(tsFactory).isSupportedToken(tokens[i])) revert TokenNotTradingSupported();

            address tradingSafe = ITradingSafeFactory(tsFactory).getDeterministicAddress(topUps[i]);
            if (!ITradingSafeFactory(tsFactory).isEtherFiSafe(tradingSafe)) revert TradingSafeNotDeployed();

            TopUp(payable(topUps[i])).redirectToTradingSafe(tokens[i], tradingSafe, amounts[i]);
            emit RedirectFunds(topUps[i], tradingSafe, tokens[i], amounts[i]);
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
