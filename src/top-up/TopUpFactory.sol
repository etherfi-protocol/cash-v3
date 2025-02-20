// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BeaconFactory, UpgradeableBeacon } from "../beacon-factory/BeaconFactory.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { DelegateCallLib } from "../libraries/DelegateCallLib.sol";
import { TopUp } from "./TopUp.sol";
import { BridgeAdapterBase } from "./bridge/BridgeAdapterBase.sol";

/**
 * @title TopUpFactory
 * @notice Factory contract for deploying TopUp instances using the beacon proxy pattern
 * @dev Extends BeaconFactory to provide Beacon Proxy deployment functionality
 * @author ether.fi
 */
contract TopUpFactory is BeaconFactory {
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
        /// @notice Mapping of token addresses to their bridge configuration
        mapping(address token => TokenConfig config) tokenConfig;
        /// @notice Address of the wallet used for emergency fund recovery
        address recoveryWallet;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TopUpFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TopUpFactoryStorageLocation = 0xe4e747da44afe6bc45062fa78d7d038abc167c5a78dee3046108b9cc47b1b100;

    /// @notice Max slippage allowed for briging
    uint96 public constant MAX_ALLOWED_SLIPPAGE = 200; // 2%

    /// @notice Emitted when tokens are bridged to the destination chain
    /// @param token The address of the token being bridged
    /// @param amount The amount of tokens being bridged
    event Bridge(address indexed token, uint256 amount);

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
    event TokenConfigSet(address[] tokens, TokenConfig[] config);

    /// @notice Error thrown when a non-admin tries to deploy a topUp contract
    error OnlyAdmin();
    /// @notice Error thrown when trying to pull funds from an address not registered as deployedAddresses
    error InvalidTopUpAddress();
    /// @notice Error thrown when zero address is provided for a token
    error TokenCannotBeZeroAddress();
    /// @notice Error thrown when attempting to bridge a token without configuration
    error TokenConfigNotSet();
    /// @notice Error thrown when attempting to bridge with zero balance
    error ZeroBalance();
    /// @notice Error thrown when recovery wallet is not set
    error RecoveryWalletNotSet();
    /// @notice Error thrown when attempting to set zero address as recovery wallet
    error RecoveryWalletCannotBeZeroAddress();
    /// @notice Error thrown when attempting to recover token which is a supported asset
    error OnlyUnsupportedTokens();
    /// @notice Error thrown when array lengths mismatch
    error ArrayLengthMismatch();
    /// @notice Error thrown when the start index is invalid
    error InvalidStartIndex();
    /// @notice Error thrown when the token config passed is invalid
    error InvalidConfig();

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
     * @dev Only callable by addresses with FACTORY_ADMIN_ROLE
     * @param salt The salt value used for deterministic deployment
     * @custom:throws OnlyAdmin if caller doesn't have admin role
     */
    function deployTopUpContract(bytes32 salt) external {
        if (!roleRegistry().hasRole(FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        bytes memory initData = abi.encodeWithSelector(TopUp.initialize.selector, address(this));
        address deployed = _deployBeacon(salt, initData);

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        $.deployedAddresses.add(deployed);
    }

    /**
     * @notice Pulls specified tokens from a range of deployed topUp contracts
     * @dev Iterates through deployed topUp contracts starting at index 'start' and calls pullFunds on each
     * @param tokens Array of token addresses to pull from each topUp contract
     * @param start Starting index in the deployedAddresses array
     * @param n Number of topUp contracts to process
     * @custom:throws If start + n exceeds the number of deployed topUp contracts
     * @custom:throws If any topUp's pullFunds call fails
     */
    function pullFunds(address[] calldata tokens, uint256 start, uint256 n) external {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        uint256 length = $.deployedAddresses.length();
        if (start >= length) revert InvalidStartIndex();
        if (start + n > length) n = length - start;

        for (uint256 i = 0; i < n;) {
            TopUp($.deployedAddresses.at(start + i)).pullFunds(tokens);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Pulls specified tokens from a given topUp contract
     * @dev Verifies the topUp contract is valid before attempting to pull funds
     * @param tokens Array of token addresses to pull from the TopUp contract
     * @param topUpContract Address of the topUp contract to pull funds from
     * @custom:throws InvalidTopUpAddress if the TopUp address is not a deployed TopUp contract
     * @custom:throws If the TopUp contracts's pullFunds call fails
     */
    function pullFundsFromTopUpContract(address[] calldata tokens, address topUpContract) external {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        if (!$.deployedAddresses.contains(topUpContract)) revert InvalidTopUpAddress();
        TopUp(topUpContract).pullFunds(tokens);
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
    function setTokenConfig(address[] calldata tokens, TokenConfig[] calldata configs) external {
        if (!roleRegistry().hasRole(FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();

        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        uint256 len = tokens.length;
        if (len != configs.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            if (tokens[i] == address(0)) revert TokenCannotBeZeroAddress();
            if (configs[i].bridgeAdapter == address(0) || configs[i].recipientOnDestChain == address(0) || configs[i].maxSlippageInBps > MAX_ALLOWED_SLIPPAGE) revert InvalidConfig();

            $.tokenConfig[tokens[i]] = configs[i];
            unchecked {
                ++i;
            }
        }

        emit TokenConfigSet(tokens, configs);
    }

    /**
     * @notice Bridges tokens to the destination chain using the configured bridge adapter
     * @dev Uses delegate call to execute the bridge operation through the appropriate adapter
     * @param token The address of the token to bridge
     * @custom:throws TokenCannotBeZeroAddress if token address is zero
     * @custom:throws TokenConfigNotSet if bridge configuration is not set for the token
     * @custom:throws ZeroBalance if contract has no balance of the specified token
     */
    function bridge(address token) external payable whenNotPaused {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (token == address(0)) revert TokenCannotBeZeroAddress();
        if ($.tokenConfig[token].bridgeAdapter == address(0)) revert TokenConfigNotSet();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        DelegateCallLib.delegateCall($.tokenConfig[token].bridgeAdapter, abi.encodeWithSelector(BridgeAdapterBase.bridge.selector, token, balance, $.tokenConfig[token].recipientOnDestChain, $.tokenConfig[token].maxSlippageInBps, $.tokenConfig[token].additionalData));

        emit Bridge(token, balance);
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
    function recoverFunds(address token, uint256 amount) external {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (!roleRegistry().hasRole(FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        if (token == address(0)) revert TokenCannotBeZeroAddress();
        if ($.tokenConfig[token].bridgeAdapter != address(0)) revert OnlyUnsupportedTokens();
        if ($.recoveryWallet == address(0)) revert RecoveryWalletNotSet();

        IERC20(token).safeTransfer($.recoveryWallet, amount);

        emit Recovery($.recoveryWallet, token, amount);
    }

    /**
     * @notice Sets the recovery wallet address for emergency fund recovery
     * @dev Only callable by admin role
     * @param _recoveryWallet The new recovery wallet address
     * @custom:throws OnlyAdmin if caller doesn't have admin role
     * @custom:throws RecoveryWalletCannotBeZeroAddress if provided address is zero
     */
    function setRecoveryWallet(address _recoveryWallet) external {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (!roleRegistry().hasRole(FACTORY_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
        if (_recoveryWallet == address(0)) revert RecoveryWalletCannotBeZeroAddress();
        emit RecoveryWalletSet($.recoveryWallet, _recoveryWallet);
        $.recoveryWallet = _recoveryWallet;
    }

    receive() external payable { }

    /**
     * @notice Gets the bridge fee for a token transfer
     * @dev Queries the bridge adapter for the fee estimation
     * @param token The address of the token to bridge
     * @return _token The fee token address
     * @return _amount The fee amount in the _token's decimals
     * @custom:throws TokenCannotBeZeroAddress if token address is zero
     * @custom:throws TokenConfigNotSet if bridge configuration is not set for the token
     * @custom:throws ZeroBalance if contract has no balance of the specified token
     */
    function getBridgeFee(address token) external view returns (address _token, uint256 _amount) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();

        if (token == address(0)) revert TokenCannotBeZeroAddress();
        if ($.tokenConfig[token].bridgeAdapter == address(0)) revert TokenConfigNotSet();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        return BridgeAdapterBase($.tokenConfig[token].bridgeAdapter).getBridgeFee(token, balance, $.tokenConfig[token].recipientOnDestChain, $.tokenConfig[token].maxSlippageInBps, $.tokenConfig[token].additionalData);
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
     * @notice Gets the bridge configuration for a specific token
     * @dev Returns the TokenConfig struct containing bridge settings
     * @param token The address of the token to query
     * @return Configuration parameters for the specified token
     */
    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        TopUpFactoryStorage storage $ = _getTopUpFactoryStorage();
        return $.tokenConfig[token];
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
        return $.tokenConfig[token].bridgeAdapter != address(0);
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
