// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { SpendingLimit, SpendingLimitLib } from "../libraries/SpendingLimitLib.sol";

/**
 * @title BinSponsor
 * @notice Defines the bin sponsors or card issuers
 */
enum BinSponsor {
    Reap,
    Rain
}

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
    /// @notice Timestamp when a pending change to Credit mode will take effect (0 if no pending change)
    uint256 incomingCreditModeStartTime;
    /// @notice Tier level of the safe that determines cashback percentages
    SafeTiers safeTier;
    /// @notice Mapping of transaction IDs to cleared status to prevent replay attacks
    mapping(bytes32 txId => bool cleared) transactionCleared;
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
    /// @notice Timestamp when a pending change to Credit mode will take effect (0 if no pending change)
    uint256 incomingCreditModeStartTime;
}

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

    /// @notice Error thrown when a recipient address is zero
    error RecipientCannotBeAddressZero();

    /// @notice Error thrown when caller doesn't have the Cash Module Controller role
    error OnlyCashModuleController();

    /// @notice Error thrown when a withdrawal is attempted before the delay period
    error CannotWithdrawYet();

    /// @notice Error thrown when signature verification fails
    error InvalidSignatures();

    /// @notice Error thrown when trying to set a mode that's already active
    error ModeAlreadySet();

    /// @notice Error thrown when a non-DebtManager contract calls restricted functions
    error OnlyDebtManager();

    /// @notice Error thrown when trying to set a tier that's already set
    error AlreadyInSameTier(uint256 index);

    /// @notice Error thrown when a cashback percentage exceeds max allowed
    error CashbackPercentageGreaterThanMaxAllowed();

    /// @notice Error thrown when trying to set a split percentage that's already set
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

    /// @notice Error thrown when trying to use multiple tokens in credit mode
    error OnlyOneTokenAllowedInCreditMode();

    /// @notice Error thrown when trying to withdraw an non whitelisted asset
    /// @param asset The address of the invalid asset
    error InvalidWithdrawAsset(address asset);

    /**
     * @notice Role identifier for EtherFi wallet access control
     * @return The role identifier as bytes32
     */
    function ETHER_FI_WALLET_ROLE() external pure returns (bytes32);

    /**
     * @notice Role identifier for Cash Module controller access
     * @return The role identifier as bytes32
     */
    function CASH_MODULE_CONTROLLER_ROLE() external pure returns (bytes32);

    /**
     * @notice Maximum allowed cashback percentage (10%)
     * @return The maximum percentage in basis points
     */
    function MAX_CASHBACK_PERCENTAGE() external pure returns (uint256);

    /**
     * @notice Represents 100% in basis points (10,000)
     * @return 100% value in basis points
     */
    function HUNDRED_PERCENT_IN_BPS() external pure returns (uint256);

    /**
     * @notice Returns if an asset is a whitelisted withdraw asset
     * @param asset Address of the asset
     * @return True if asset is whitelisted for withdrawals, false otherwise
     */
    function isWhitelistedWithdrawAsset(address asset) external view returns (bool);

    /**
     * @notice Returns all the assets whitelisted for withdrawals
     * @return Array of whitelisted withdraw assets
     */    
    function getWhitelistedWithdrawAssets() external view returns (address[] memory);

    /**
     * @notice Retrieves cash configuration data for a Safe
     * @param safe Address of the EtherFi Safe
     * @return Data structure containing Safe cash configuration
     * @custom:throws OnlyEtherFiSafe if the address is not a valid EtherFi Safe
     */
    function getData(address safe) external view returns (SafeData memory);

    /**
     * @notice Checks if a transaction has been cleared
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @return Boolean indicating if the transaction is cleared
     * @custom:throws OnlyEtherFiSafe if the address is not a valid EtherFi Safe
     */
    function transactionCleared(address safe, bytes32 txId) external view returns (bool);

    /**
     * @notice Gets the debt manager contract
     * @return IDebtManager instance
     */
    function getDebtManager() external view returns (IDebtManager);

    /**
     * @notice Gets the settlement dispatcher address
     * @dev The settlement dispatcher receives the funds that are spent
     * @param binSponsor Bin sponsor for which the settlement dispatcher needs to be returned
     * @return settlementDispatcher The address of the settlement dispatcher
     */
    function getSettlementDispatcher(BinSponsor binSponsor) external view returns (address settlementDispatcher);

    /**
     * @notice Gets the cashback percentage and split percentage for a safe
     * @dev Returns the tier-based cashback percentage and safe's split configuration
     * @param safe Address of the EtherFi Safe
     * @return Cashback percentage in basis points (100 = 1%)
     * @return Split percentage to safe in basis points (5000 = 50%)
     * @custom:throws OnlyEtherFiSafe if the address is not a valid EtherFi Safe
     */
    function getSafeCashbackPercentageAndSplit(address safe) external view returns (uint256, uint256);

    /**
     * @notice Returns the EtherFiDataProvider contract reference
     * @dev Used to access global system configuration and services
     * @return The EtherFiDataProvider contract instance
     */
    function etherFiDataProvider() external view returns (IEtherFiDataProvider);

    /**
     * @notice Gets the pending cashback amount for an account in USD
     * @dev Returns the amount of cashback waiting to be claimed
     * @param account Address of the account (safe or spender)
     * @return Pending cashback amount in USD
     */
    function getPendingCashback(address account) external view returns (uint256);

    /**
     * @notice Gets the current delay settings for the module
     * @return withdrawalDelay Delay in seconds before a withdrawal can be finalized
     * @return spendLimitDelay Delay in seconds before spending limit changes take effect
     * @return modeDelay Delay in seconds before a mode change takes effect
     */
    function getDelays() external view returns (uint64, uint64, uint64);

    /**
     * @notice Gets the current operating mode of a safe
     * @dev Considers pending mode changes that have passed their delay
     * @param safe Address of the EtherFi Safe
     * @return The current operating mode (Debit or Credit)
     */
    function getMode(address safe) external view returns (Mode);

    /**
     * @notice Gets the referrer cashback percentage in bps
     * @return uint64 referrer cashback percentage in bps
     */
    function getReferrerCashbackPercentage() external view returns (uint64);

    /**
     * @notice Gets the timestamp when a pending credit mode change will take effect
     * @dev Returns 0 if no pending change or if the safe uses debit mode
     * @param safe Address of the EtherFi Safe
     * @return Timestamp when credit mode will take effect, or 0 if not applicable
     */
    function incomingCreditModeStartTime(address safe) external view returns (uint256);

    /**
     * @notice Gets the pending withdrawal amount for a token
     * @dev Only callable for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to check
     * @return Amount of tokens pending withdrawal
     * @custom:throws OnlyEtherFiSafe if the address is not a valid EtherFi Safe
     */
    function getPendingWithdrawalAmount(address safe, address token) external view returns (uint256);

    /**
     * @notice Sets up a new Safe's Cash Module with initial configuration
     * @dev Creates default spending limits and sets initial mode to Debit with 50% cashback split
     * @param data The encoded initialization data containing daily limit, monthly limit, and timezone offset
     * @custom:throws OnlyEtherFiSafe if the caller is not a valid EtherFi Safe
     */
    function setupModule(bytes calldata data) external;

    /**
     * @notice Initializes the CashModule contract
     * @dev Sets up the role registry, debt manager, settlement dispatcher, and data providers
     * @param _roleRegistry Address of the role registry contract
     * @param _debtManager Address of the debt manager contract
     * @param _settlementDispatcherReap Address of the settlement dispatcher for Reap
     * @param _settlementDispatcherRain Address of the settlement dispatcher for Rain
     * @param _cashbackDispatcher Address of the cashback dispatcher
     * @param _cashEventEmitter Address of the cash event emitter
     * @param _cashModuleSetters Address of the cash module setters contract
     * @custom:throws InvalidInput if any essential address is zero
     */
    function initialize(address _roleRegistry, address _debtManager, address _settlementDispatcherReap, address _settlementDispatcherRain, address _cashbackDispatcher, address _cashEventEmitter, address _cashModuleSetters) external;

    /**
     * @notice Configures the withdraw assets whitelist
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param assets Array of asset addresses to configure 
     * @param shouldWhitelist Array of boolean suggesting whether to whitelist the assets
     * @custom:throws OnlyCashModuleController if the caller does not have CASH_MODULE_CONTROLLER_ROLE role
     * @custom:throws InvalidInput If the arrays are empty
     * @custom:throws ArrayLengthMismatch If the arrays have different lengths
     * @custom:throws InvalidAddress If any address is the zero address
     * @custom:throws DuplicateElementFound If any address appears more than once in the addrs array
     */
    function configureWithdrawAssets(address[] calldata assets, bool[] calldata shouldWhitelist) external;

    /**
     * @notice Sets the settlement dispatcher address for a bin sponsor
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param binSponsor Bin sponsor for which the settlement dispatcher is updated
     * @param dispatcher Address of the new settlement dispatcher for the bin sponsor
     * @custom:throws InvalidInput if caller doesn't have the controller role
     */
    function setSettlementDispatcher(BinSponsor binSponsor, address dispatcher) external;

    /**
     * @notice Sets the tier for one or more safes
     * @dev Assigns tiers which determine cashback percentages
     * @param safes Array of safe addresses to update
     * @param tiers Array of tiers to assign to the corresponding safe addresses
     * @custom:throws OnlyEtherFiWallet if caller doesn't have the wallet role
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws OnlyEtherFiSafe if any address is not a valid EtherFi Safe
     * @custom:throws AlreadyInSameTier if a safe is already in the specified tier
     */
    function setSafeTier(address[] memory safes, SafeTiers[] memory tiers) external;

    /**
     * @notice Sets the cashback percentage for different tiers
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param tiers Array of tiers to configure
     * @param cashbackPercentages Array of cashback percentages in basis points (100 = 1%)
     * @custom:throws OnlyCashModuleController if caller doesn't have the controller role
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws CashbackPercentageGreaterThanMaxAllowed if any percentage exceeds the maximum allowed
     */
    function setTierCashbackPercentage(SafeTiers[] memory tiers, uint256[] memory cashbackPercentages) external;

    /**
     * @notice Sets the referrer cashback percentage in bps
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param cashbackPercentage New cashback percentage in bps
     */
    function setReferrerCashbackPercentageInBps(uint64 cashbackPercentage) external;

    /**
     * @notice Sets the percentage of cashback that goes to the safe (versus the spender)
     * @dev Can only be called by the safe itself with a valid admin signature
     * @param safe Address of the safe to configure
     * @param splitInBps Percentage in basis points to allocate to the safe (10000 = 100%)
     * @param signer Address of the safe admin signing the transaction
     * @param signature Signature from the signer authorizing this change
     * @custom:throws OnlyEtherFiSafe if the caller is not a valid EtherFi Safe
     * @custom:throws OnlySafeAdmin if signer is not a safe admin
     * @custom:throws SplitAlreadyTheSame if the new split is the same as the current one
     * @custom:throws InvalidInput if the split percentage exceeds 100%
     * @custom:throws InvalidSignatures if signature verification fails
     */
    function setCashbackSplitToSafeBps(address safe, uint256 splitInBps, address signer, bytes calldata signature) external;

    /**
     * @notice Sets the time delays for withdrawals, spending limit changes, and mode changes
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param withdrawalDelay Delay in seconds before a withdrawal can be finalized
     * @param spendLimitDelay Delay in seconds before spending limit changes take effect
     * @param modeDelay Delay in seconds before a mode change takes effect
     * @custom:throws OnlyCashModuleController if caller doesn't have the controller role
     */
    function setDelays(uint64 withdrawalDelay, uint64 spendLimitDelay, uint64 modeDelay) external;

    /**
     * @notice Sets the operating mode for a safe
     * @dev Switches between Debit and Credit modes, with possible delay for Credit mode
     * @param safe Address of the EtherFi Safe
     * @param mode The target mode (Debit or Credit)
     * @param signer Address of the safe admin signing the transaction
     * @param signature Signature from the signer authorizing this mode change
     * @custom:throws OnlyEtherFiSafe if the caller is not a valid EtherFi Safe
     * @custom:throws OnlySafeAdmin if signer is not a safe admin
     * @custom:throws ModeAlreadySet if the safe is already in the requested mode
     * @custom:throws InvalidSignatures if signature verification fails
     */
    function setMode(address safe, Mode mode, address signer, bytes calldata signature) external;

    /**
     * @notice Updates the spending limits for a safe
     * @dev Can only be called by the safe itself with a valid admin signature
     * @param safe Address of the EtherFi Safe
     * @param dailyLimitInUsd New daily spending limit in USD
     * @param monthlyLimitInUsd New monthly spending limit in USD
     * @param signer Address of the safe admin signing the transaction
     * @param signature Signature from the signer authorizing this update
     * @custom:throws OnlyEtherFiSafe if the caller is not a valid EtherFi Safe
     * @custom:throws OnlySafeAdmin if signer is not a safe admin
     * @custom:throws InvalidSignatures if signature verification fails
     */
    function updateSpendingLimit(address safe, uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, address signer, bytes calldata signature) external;

    /**
     * @notice Processes a spending transaction with multiple tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param spender Address of the spendeer
     * @param referrer Address of the referrer 
     * @param txId Transaction identifier
     * @param binSponsor Bin sponsor used for spending
     * @param tokens Array of addresses of the tokens to spend
     * @param amountsInUsd Array of amounts to spend in USD (must match tokens array length)
     * @param shouldReceiveCashback Yes if tx should receive cashback, to block cashbacks for some types of txs like ATM withdrawals
     * @custom:throws TransactionAlreadyCleared if the transaction was already processed
     * @custom:throws UnsupportedToken if any token is not supported
     * @custom:throws AmountZero if any converted amount is zero
     * @custom:throws ArrayLengthMismatch if token and amount arrays have different lengths
     * @custom:throws OnlyOneTokenAllowedInCreditMode if multiple tokens are used in credit mode
     * @custom:throws If spending would exceed limits or balances
     */
    function spend(address safe,  address spender, address referrer,  bytes32 txId, BinSponsor binSponsor,  address[] calldata tokens,  uint256[] calldata amountsInUsd,  bool shouldReceiveCashback) external;

    /**
     * @notice Clears pending cashback for users
     * @param users Addresses of users to clear the pending cashback for
     */
    function clearPendingCashback(address[] calldata users) external;

    /**
     * @notice Repays borrowed tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws OnlyEtherFiWallet if caller doesn't have the wallet role
     * @custom:throws OnlyEtherFiSafe if the safe is not a valid EtherFi Safe
     * @custom:throws OnlyBorrowToken if token is not a valid borrow token
     * @custom:throws AmountZero if the converted amount is zero
     * @custom:throws InsufficientBalance if there is not enough balance for the operation
     */
    function repay(address safe, address token, uint256 amountInUsd) external;

    /**
     * @notice Requests a withdrawal of tokens to a recipient
     * @dev Creates a pending withdrawal request that can be processed after the delay period
     * @dev Can only be done by the quorum of owners of the safe
     * @param safe Address of the EtherFi Safe
     * @param tokens Array of token addresses to withdraw
     * @param amounts Array of token amounts to withdraw
     * @param recipient Address to receive the withdrawn tokens 
     * @param signers Array of safe owner addresses signing the transaction
     * @param signatures Array of signatures from the safe owners
     * @custom:throws OnlyEtherFiSafe if the caller is not a valid EtherFi Safe
     * @custom:throws InvalidSignatures if signature verification fails
     * @custom:throws RecipientCannotBeAddressZero if recipient is the zero address
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws InsufficientBalance if any token has insufficient balance
     */
    function requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, address[] calldata signers, bytes[] calldata signatures) external;

    /**
     * @notice Processes a pending withdrawal request after the delay period
     * @dev Executes the token transfers and clears the request
     * @param safe Address of the EtherFi Safe
     * @custom:throws OnlyEtherFiSafe if the caller is not a valid EtherFi Safe
     * @custom:throws CannotWithdrawYet if the withdrawal delay period hasn't passed
     */
    function processWithdrawal(address safe) external;

    /**
     * @notice Prepares a safe for liquidation by canceling any pending withdrawals
     * @dev Only callable by the DebtManager
     * @param safe Address of the EtherFi Safe being liquidated
     * @custom:throws OnlyDebtManager if called by any address other than the DebtManager
     */
    function preLiquidate(address safe) external;

    /**
     * @notice Executes post-liquidation logic to transfer tokens to the liquidator
     * @dev Only callable by the DebtManager after a successful liquidation
     * @param safe Address of the EtherFi Safe being liquidated
     * @param liquidator Address that will receive the liquidated tokens
     * @param tokensToSend Array of token data with amounts to send to the liquidator
     * @custom:throws OnlyDebtManager if called by any address other than the DebtManager
     */
    function postLiquidate(address safe, address liquidator, IDebtManager.LiquidationTokenData[] memory tokensToSend) external;

    /**
     * @notice Returns the current nonce for a Safe
     * @param safe The Safe address to query
     * @return Current nonce value
     * @dev Nonces are used to prevent signature replay attacks
     */
    function getNonce(address safe) external view returns (uint256);

    /**
     * @notice Sets the new CashModuleSetters implementation address
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param newCashModuleSetters Address of the new CashModuleSetters implementation
     * @custom:throws OnlyCashModuleController if caller doesn't have the controller role
     * @custom:throws InvalidInput if newCashModuleSetters = address(0)
     */
    function setCashModuleSettersAddress(address newCashModuleSetters) external;

    /**
     * @notice Fetched the safe tier
     * @param safe Address of the safe
     * @return SafeTiers Tier of the safe
     */
    function getSafeTier(address safe) external view returns (SafeTiers);
    
    /**
     * @notice Fetches Cashback Percentage for a safe tier
     * @return uint256 Cashback Percentage in bps
     */
    function getTierCashbackPercentage(SafeTiers tier) external view returns (uint256);
}
