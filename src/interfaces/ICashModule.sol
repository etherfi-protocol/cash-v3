// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { SpendingLimit, SpendingLimitLib } from "../libraries/SpendingLimitLib.sol";

/**
 * @title Mode
 * @notice Defines the operating mode for cash spending operations
 * @dev Credit mode borrows tokens, Debit mode uses balance from the safe
 */
enum Mode {
    Credit,
    Debit
}

/**
 * @title WithdrawalRequest
 * @notice Structure representing a pending withdrawal of tokens
 * @dev Includes tokens, amounts, recipient, and finalization timestamp
 */
struct WithdrawalRequest {
    address[] tokens;
    uint256[] amounts;
    address recipient;
    uint96 finalizeTime;
}

/**
 * @title SafeData
 * @notice View-only representation of a Safe's cash configuration
 * @dev Used for returning Safe data in external-facing functions
 */
struct SafeData {
    /// @notice Spend limit for the user
    SpendingLimit spendingLimit;
    /// @notice Impending withdrawal request for the user
    WithdrawalRequest pendingWithdrawalRequest;
    /// @notice User's chosen mode
    Mode mode;
    /// @notice Start time for credit mode
    uint256 incomingCreditModeStartTime;
    /// @notice Running total of all cashback earned by this safe (and its spenders) in USD
    uint256 totalCashbackEarnedInUsd;
}

/**
 * @notice SafeTiers
 * @dev Gets cashback based on the safe tier
 */
enum SafeTiers {
    Pepe,
    Wojak,
    Chad,
    Whale,
    Business
}

/**
 * @title SafeCashConfig
 * @notice Complete storage representation of a Safe's cash configuration
 * @dev Includes all data needed for managing a Safe's cash operations
 */
struct SafeCashConfig {
    /// @notice Spending limit configuration including daily and monthly limits
    SpendingLimit spendingLimit;
    /// @notice Pending withdrawal request with token addresses, amounts, recipient, and finalization time
    WithdrawalRequest pendingWithdrawalRequest;
    /// @notice Current operating mode (Credit or Debit) for spending transactions
    Mode mode;
    /// @notice Mapping of transaction IDs to cleared status to prevent replay attacks
    mapping(bytes32 txId => bool cleared) transactionCleared;
    /// @notice Timestamp when a pending change to Credit mode will take effect (0 if no pending change)
    uint256 incomingCreditModeStartTime;
    /// @notice Set of whitelisted addresses that can receive withdrawals from this safe
    EnumerableSetLib.AddressSet withdrawRecipients;
    /// @notice Tier level of the safe that determines cashback percentages
    SafeTiers safeTier;
    /// @notice Percentage of cashback allocated to the safe vs. the spender (in basis points, 5000 = 50%)
    uint256 cashbackSplitToSafePercentage;
    /// @notice Running total of all cashback earned by this safe (and its spenders) in USD
    uint256 totalCashbackEarnedInUsd;
}

/**
 * @title SafeCashData
 * @notice Comprehensive data structure for front-end display of Safe cash state
 * @dev Aggregates data from multiple sources for a complete view of a Safe's financial state
 */
struct SafeCashData {
    /// @notice Current operating mode (Credit or Debit)
    Mode mode;
    /// @notice Array of collateral token balances
    IDebtManager.TokenData[] collateralBalances;
    /// @notice Array of borrowed token balances
    IDebtManager.TokenData[] borrows;
    /// @notice Array of token prices
    IDebtManager.TokenData[] tokenPrices;
    /// @notice Current withdrawal request
    WithdrawalRequest withdrawalRequest;
    /// @notice Total value of collateral in USD
    uint256 totalCollateral;
    /// @notice Total value of borrows in USD
    uint256 totalBorrow;
    /// @notice Maximum borrowing power in USD
    uint256 maxBorrow;
    /// @notice Maximum spendable amount in Credit mode (USD)
    uint256 creditMaxSpend;
    /// @notice Maximum spendable amount in Debit mode (USD)
    uint256 debitMaxSpend;
    /// @notice Remaining spending limit allowance
    uint256 spendingLimitAllowance;
    /// @notice Running total of all cashback earned by this safe (and its spenders) in USD
    uint256 totalCashbackEarnedInUsd;
}

/**
 * @title ICashModule
 * @notice Interface for interacting with the CashModule contract
 * @dev Provides methods to retrieve Safe data and relevant contract references
 * @author ether.fi
 */
interface ICashModule {
    /// @notice Error thrown when a transaction has already been cleared
    error TransactionAlreadyCleared();

    /// @notice Error thrown when a non-EtherFi wallet tries to access restricted functions
    error OnlyEtherFiWallet();

    /// @notice Error thrown when an unsupported token is used
    error UnsupportedToken();

    /// @notice Error thrown when a token that is not a borrow token is used in certain operations
    error OnlyBorrowToken();

    /// @notice Error thrown when an operation amount is zero
    error AmountZero();

    /// @notice Error thrown when a balance is insufficient for an operation
    error InsufficientBalance();

    /// @notice Error thrown when borrowings would exceed maximum allowed after a spending operation
    error BorrowingsExceedMaxBorrowAfterSpending();
    error RecipientCannotBeAddressZero();
    error OnlyCashModuleController();
    error CannotWithdrawYet();
    error OnlyWhitelistedWithdrawRecipients();
    error InvalidSignatures();
    error ModeAlreadySet();
    error OnlyDebtManager();
    error AlreadyInSameTier(uint256 index);
    error CashbackPercentageGreaterThanMaxAllowed();
    error SplitAlreadyTheSame();
    /// @notice Throws when the msg.sender is not an admin to the safe
    error OnlySafeAdmin();
    /// @notice Thrown when the input is invalid
    error InvalidInput();
    /// @notice Thrown when the signature verification fails
    error InvalidSignature();
    /// @notice Thrown when there is an array length mismatch
    error ArrayLengthMismatch();
    /// @notice Thrown when the caller is not an EtherFi Safe
    error OnlyEtherFiSafe();

    function ETHER_FI_WALLET_ROLE() external pure returns (bytes32);
    function CASH_MODULE_CONTROLLER_ROLE() external pure returns (bytes32);
    function MAX_CASHBACK_PERCENTAGE() external pure returns (uint256);
    function HUNDRED_PERCENT_IN_BPS() external pure returns (uint256);

    // Core view functions
    function getData(address safe) external view returns (SafeData memory);
    function transactionCleared(address safe, bytes32 txId) external view returns (bool);
    function getDebtManager() external view returns (IDebtManager);
    function getSettlementDispatcher() external view returns (address);
    function getSafeCashbackPercentageAndSplit(address safe) external view returns (uint256, uint256);
    function etherFiDataProvider() external view returns (IEtherFiDataProvider);
    function getPendingCashback(address account) external view returns (uint256);
    function getDelays() external view returns (uint64, uint64, uint64);
    function getMode(address safe) external view returns (Mode);
    function incomingCreditModeStartTime(address safe) external view returns (uint256);
    function getWithdrawRecipients(address safe) external view returns (address[] memory);
    function isWhitelistedWithdrawRecipient(address safe, address account) external view returns (bool);
    function getPendingWithdrawalAmount(address safe, address token) external view returns (uint256);

    // Setup and initialization
    function setupModule(bytes calldata data) external;
    function initialize(address _roleRegistry, address _debtManager, address _settlementDispatcher, address _cashbackDispatcher, address _cashEventEmitter, address _cashModuleSetters) external;

    // Setter functions
    function setSafeTier(address[] memory safes, SafeTiers[] memory tiers) external;
    function setTierCashbackPercentage(SafeTiers[] memory tiers, uint256[] memory cashbackPercentages) external;
    function setCashbackSplitToSafeBps(address safe, uint256 splitInBps, address signer, bytes calldata signature) external;
    function setDelays(uint64 withdrawalDelay, uint64 spendLimitDelay, uint64 modeDelay) external;
    function setMode(address safe, Mode mode, address signer, bytes calldata signature) external;
    function updateSpendingLimit(address safe, uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, address signer, bytes calldata signature) external;

    // Debit/Credit operations
    function spend(address safe, address spender, bytes32 txId, address token, uint256 amountInUsd) external;
    function repay(address safe, address token, uint256 amountInUsd) external;

    // Withdrawal operations
    function configureWithdrawRecipients(address safe, address[] calldata withdrawRecipients, bool[] calldata shouldWhitelist, address[] calldata signers, bytes[] calldata signatures) external;
    function requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, address[] calldata signers, bytes[] calldata signatures) external;
    function processWithdrawal(address safe) external;

    // Liquidation functions
    function preLiquidate(address safe) external;
    function postLiquidate(address safe, address liquidator, IDebtManager.LiquidationTokenData[] memory tokensToSend) external;

    /**
     * @notice Returns the current nonce for a Safe
     * @param safe The Safe address to query
     * @return Current nonce value
     * @dev Nonces are used to prevent signature replay attacks
     */
    function getNonce(address safe) external view returns (uint256);
}
