// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title TopUpDest
 * @notice Contract for managing token deposits and disbursements to EtherFi safes
 * @dev Extends UpgradeableProxy with reentrancy protection and pause functionality
 * @author ether.fi
 */
contract TopUpDest is UpgradeableProxy {
    using SafeERC20 for IERC20;

    /// @notice Role identifier for accounts authorized to deposit tokens
    bytes32 public constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Role identifier for accounts authorized to top up user safes
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    IEtherFiDataProvider public immutable etherFiDataProvider;

    /**
     * @dev Storage structure for TopUpDest using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.TopUpDest
     */
    struct TopUpDestStorage {
        /// @notice Tracks the total deposits for each token
        mapping(address token => uint256 deposits) deposits;

        /// @notice Tracks whether a transaction has been processed
        mapping(bytes32 txId => bool completed) transactionCompleted;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.TopUpDest")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TopUpDestStorageLocation = 0xcf0121b0f46cee8ebfce652f58f0ad785e4fcd91a62127b83995179fc450fe00;

    /**
     * @notice Emitted when tokens are deposited into the contract
     * @param token Address of the deposited token
     * @param amount Amount of tokens deposited
     */
    event Deposit(address indexed token, uint256 amount);

    /**
     * @notice Emitted when tokens are withdrawn from the contract
     * @param token Address of the withdrawn token
     * @param amount Amount of tokens withdrawn
     */
    event Withdrawal(address indexed token, uint256 amount);

    /**
     * @notice Emitted when tokens are sent to a user's safe
     * @param txId TxId created for deduplication = keccak256(txhash || token || user)
     * @param user Address of the recipient safe
     * @param sourceTxHash Tx hash for the source tx
     * @param chainId ID of the blockchain where the user topped up
     * @param token Address of the token used for top-up
     * @param amount Amount of tokens sent
     */
    event TopUp(bytes32 indexed txId, address indexed user, address indexed token, bytes32 sourceTxHash, uint256 chainId, uint256 amount);

    /// @notice Error thrown when the contract has insufficient token balance
    error BalanceTooLow();

    /// @notice Error thrown when withdrawal amount exceeds deposit
    error AmountGreaterThanDeposit();

    /// @notice Error thrown when a zero amount is provided
    error AmountCannotBeZero();

    /// @notice Error thrown when an operation is attempted on an unregistered safe
    error NotARegisteredSafe();

    /// @notice Error thrown when input arrays have different lengths
    error ArrayLengthMismatch();

    /// @notice Error thrown when the topup is already processed
    error TopUpAlreadyProcessed();

    /**
     * @dev Constructor that disables initializers to prevent implementation contract initialization
     */
    constructor(address _etherFiDataProvider) {
        etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
        _disableInitializers();
    }

    /**
     * @notice Initializes the TopUpDest contract
     * @dev Sets up role registry, reentrancy guard, and data provider
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @dev Internal function to access the contract's storage
     * @return $ Storage pointer to the TopUpDestStorage struct
     */
    function _getTopUpDestStorage() internal pure returns (TopUpDestStorage storage $) {
        assembly {
            $.slot := TopUpDestStorageLocation
        }
    }

    /**
     * @notice Deposits tokens into the contract
     * @dev Only callable by accounts with TOP_UP_DEPOSITOR_ROLE
     * @param token Address of the token to deposit
     * @param amount Amount of tokens to deposit
     * @custom:throws AmountCannotBeZero if amount is zero
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function deposit(address token, uint256 amount) external onlyRole(TOP_UP_DEPOSITOR_ROLE) {
        if (amount == 0) revert AmountCannotBeZero();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _getTopUpDestStorage().deposits[token] += amount;
        emit Deposit(token, amount);
    }

    /**
     * @notice Withdraws tokens from the contract
     * @dev Only callable by the upgrader role
     * @param token Address of the token to withdraw
     * @param amount Amount of tokens to withdraw
     * @custom:throws AmountCannotBeZero if amount is zero
     * @custom:throws AmountGreaterThanDeposit if amount exceeds available deposit
     */
    function withdraw(address token, uint256 amount) external nonReentrant onlyRoleRegistryOwner() {
        TopUpDestStorage storage $ = _getTopUpDestStorage();

        if (amount == 0) revert AmountCannotBeZero();
        if (amount > $.deposits[token]) revert AmountGreaterThanDeposit();

        $.deposits[token] -= amount;
        _transfer(msg.sender, token, amount);

        emit Withdrawal(token, amount);
    }

    /**
     * @notice Tops up multiple user safes in a single transaction
     * @dev Only callable by accounts with TOP_UP_ROLE when contract is not paused
     * @param txHashes Array of transaction hashes for source transactions
     * @param users Array of safe addresses to top up
     * @param chainIds Array of chain IDs where the user topped-up
     * @param tokens Array of token addresses to send
     * @param amounts Array of token amounts to send
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function topUpUserSafeBatch(bytes32[] memory txHashes, address[] memory users, uint256[] memory chainIds, address[] memory tokens, uint256[] memory amounts) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        uint256 len = txHashes.length;
        if (len != users.length || len != chainIds.length || len != tokens.length || len != amounts.length) revert ArrayLengthMismatch();
            
        for (uint256 i = 0; i < len;) {
            _topUp(txHashes[i], users[i], chainIds[i], tokens[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Tops up a single user safe
     * @dev Only callable by accounts with TOP_UP_ROLE when contract is not paused
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param chainId Chain ID where the user topped-up
     * @param token Address of the token to send
     * @param amount Amount of tokens to send
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function topUpUserSafe(bytes32 txHash, address user, uint256 chainId, address token, uint256 amount) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        _topUp(txHash, user, chainId, token, amount);
    }

    /**
     * @notice Internal implementation of top-up logic
     * @dev Verifies the safe, transfers tokens, and updates transaction records
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param chainId Chain ID where the user topped-up
     * @param token Address of the token to send
     * @param amount Amount of tokens to send
     * @custom:throws NotARegisteredSafe if the user address is not a registered safe
     * @custom:throws TopUpAlreadyProcessed if the transaction has already been processed
     * @custom:throws BalanceTooLow if the contract has insufficient token balance
     */
    function _topUp(bytes32 txHash, address user, uint256 chainId, address token, uint256 amount) internal {
        TopUpDestStorage storage $ = _getTopUpDestStorage();

        bytes32 txId = getTxId(txHash, user, token);
        if (!etherFiDataProvider.isEtherFiSafe(user)) revert NotARegisteredSafe();
        if ($.transactionCompleted[txId]) revert TopUpAlreadyProcessed();

        $.transactionCompleted[txId] = true;
        _transfer(user, token, amount);

        emit TopUp(txId, user, token, txHash, chainId, amount);
    }

    /**
     * @notice Gets the total deposit amount for a specific token
     * @dev Returns the current deposit balance of a token in the contract
     * @param token Address of the token to query
     * @return Amount of token deposited
     */
    function getDeposit(address token) external view returns (uint256) {
        return _getTopUpDestStorage().deposits[token];
    }

    /**
     * @notice Calculates txId based on the input parameters
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param token Address of the token to send
     * @return bytes32 txId
     */
    function getTxId(bytes32 txHash, address user, address token) public pure returns (bytes32) {
        return keccak256(abi.encode(txHash, user, token));
    }

    /**
     * @notice Checks if a transaction has been processed
     * @dev Returns boolean indicating transaction status
     * @param txHash Transaction hash on source chain
     * @param user Address of the safe to top up
     * @param token Address of the token to send
     * @return Boolean indicating whether the transaction has been processed
     */
    function isTransactionCompleted(bytes32 txHash, address user, address token) external view returns (bool) {
        return _getTopUpDestStorage().transactionCompleted[getTxId(txHash, user, token)];
    }

    /**
     * @notice Checks if a transaction has been processed based on txId
     * @dev Returns boolean indicating transaction status
     * @param txId Unique transaction identifier
     * @return Boolean indicating whether the transaction has been processed
     */
    function isTransactionCompletedByTxId(bytes32 txId) external view returns (bool) {
        return _getTopUpDestStorage().transactionCompleted[txId];
    }

    /**
     * @notice Internal function to transfer tokens to a recipient
     * @dev Checks balance before transferring
     * @param to Address of the recipient
     * @param token Address of the token to transfer
     * @param amount Amount of tokens to transfer
     * @custom:throws BalanceTooLow if the contract has insufficient token balance
     */
    function _transfer(address to, address token, uint256 amount) internal {
        if (IERC20(token).balanceOf(address(this)) < amount) revert BalanceTooLow();
        IERC20(token).safeTransfer(to, amount);
    }
}