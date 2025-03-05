// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { ReentrancyGuardTransientUpgradeable } from "../utils/ReentrancyGuardTransientUpgradeable.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title TopUpDest
 * @notice Contract for managing token deposits and disbursements to EtherFi safes
 * @dev Extends UpgradeableProxy with reentrancy protection and pause functionality
 * @author ether.fi
 */
contract TopUpDest is UpgradeableProxy, ReentrancyGuardTransientUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Role identifier for accounts authorized to deposit tokens
    bytes32 public constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Role identifier for accounts authorized to top up user safes
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    /**
     * @dev Storage structure for TopUpDest using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.TopUpDest
     */
    struct TopUpDestStorage {
        /// @notice Reference to the EtherFi data provider for safe verification
        IEtherFiDataProvider etherFiDataProvider;
        /// @notice Tracks the total deposits for each token
        mapping(address token => uint256 deposits) deposits;
        /// @notice Tracks cumulative top-ups for each user for a specific chain and token
        mapping(address user => mapping(uint256 chainId => mapping(address token => uint256 totalTopUp))) cumulativeTopUps;
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
     * @param user Address of the recipient safe
     * @param chainId ID of the blockchain where the user topped up
     * @param token Address of the token used for top-up
     * @param amount Amount of tokens sent
     * @param cumulativeAmount Total amount of tokens sent to this user on this chain
     */
    event TopUp(address indexed user, uint256 indexed chainId, address indexed token, uint256 amount, uint256 cumulativeAmount);

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

    /// @notice Error thrown when a caller lacks the required role
    error Unauthorized();

    /// @notice Error thrown when cumulative top-up is wrong
    error RaceDetected();

    /**
     * @dev Constructor that disables initializers to prevent implementation contract initialization
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the TopUpDest contract
     * @dev Sets up role registry, reentrancy guard, and data provider
     * @param _roleRegistry Address of the role registry contract
     * @param _etherFiDataProvider Address of the EtherFi data provider
     */
    function initialize(address _roleRegistry, address _etherFiDataProvider) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        __ReentrancyGuardTransient_init();
        __Pausable_init_unchained();

        _getTopUpDestStorage().etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
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
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (msg.sender != roleRegistry().owner()) revert Unauthorized();
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
     * @param users Array of safe addresses to top up
     * @param chainIds Array of chain IDs where the user topped-up
     * @param tokens Array of token addresses to send
     * @param amounts Array of token amounts to send
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function topUpUserSafeBatch(address[] memory users, uint256[] memory chainIds, address[] memory tokens, uint256[] memory amounts, uint256[] memory expectedCumulativeTopUps) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        uint256 len = chainIds.length;
        if (len != users.length || len != tokens.length || len != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len;) {
            _topUp(users[i], chainIds[i], tokens[i], amounts[i], expectedCumulativeTopUps[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Tops up a single user safe
     * @dev Only callable by accounts with TOP_UP_ROLE when contract is not paused
     * @param user Address of the safe to top up
     * @param chainId Chain ID where the user topped-up
     * @param token Address of the token to send
     * @param amount Amount of tokens to send
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    function topUpUserSafe(address user, uint256 chainId, address token, uint256 amount, uint256 expectedCumulativeTopUp) external whenNotPaused nonReentrant onlyRole(TOP_UP_ROLE) {
        _topUp(user, chainId, token, amount, expectedCumulativeTopUp);
    }

    /**
     * @notice Internal implementation of top-up logic
     * @dev Verifies the safe, transfers tokens, and updates cumulative records
     * @param user Address of the safe to top up
     * @param chainId Chain ID where the user topped-up
     * @param token Address of the token to send
     * @param amount Amount of tokens to send
     * @custom:throws NotARegisteredSafe if the user address is not a registered safe
     * @custom:throws BalanceTooLow if the contract has insufficient token balance
     */
    function _topUp(address user, uint256 chainId, address token, uint256 amount, uint256 expectedCumulativeTopUp) internal {
        TopUpDestStorage storage $ = _getTopUpDestStorage();
        if (!$.etherFiDataProvider.isEtherFiSafe(user)) revert NotARegisteredSafe();
        if ($.cumulativeTopUps[user][chainId][token] != expectedCumulativeTopUp) revert RaceDetected();

        _transfer(user, token, amount);
        $.cumulativeTopUps[user][chainId][token] += amount;

        emit TopUp(user, chainId, token, amount, $.cumulativeTopUps[user][chainId][token]);
    }

    /**
     * @notice Pauses the contract
     * @dev Only callable by accounts with the pauser role
     */
    function pause() external {
        roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /**
     * @notice Unpauses the contract
     * @dev Only callable by accounts with the unpauser role
     */
    function unpause() external {
        roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
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
     * @notice Gets the cumulative top-up amount for a user on a specific chain and token
     * @dev Returns the total amount of tokens sent to a user's safe
     * @param user Address of the user's safe
     * @param chainId ID of the blockchain where the top-ups were recorded
     * @param token Address of the token that was sent
     * @return Total amount of tokens sent to the user on the specified chain
     */
    function getCumulativeTopUp(address user, uint256 chainId, address token) external view returns (uint256) {
        return _getTopUpDestStorage().cumulativeTopUps[user][chainId][token];
    }

    /**
     * @notice Gets the EtherFi data provider address
     * @dev Returns the reference to the data provider used for safe verification
     * @return The address of the EtherFi data provider contract
     */
    function getEtherFiDataProvider() external view returns (address) {
        return address(_getTopUpDestStorage().etherFiDataProvider);
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

    /**
     * @dev Modifier to check if the caller has a specific role
     * @param role The role identifier to check
     * @custom:throws Unauthorized if caller doesn't have the required role
     */
    modifier onlyRole(bytes32 role) {
        if (!roleRegistry().hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }
}
