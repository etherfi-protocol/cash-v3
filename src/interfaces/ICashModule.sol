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
    Whale
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
    /**
     * @notice Retrieves cash configuration data for a Safe
     * @param safe Address of the EtherFi Safe
     * @return Safe data structure containing spending limits, withdrawal requests, and more
     */
    function getData(address safe) external view returns (SafeData memory);

    /**
     * @notice Checks if a transaction has been cleared
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @return Boolean indicating if the transaction is cleared
     */
    function transactionCleared(address safe, bytes32 txId) external view returns (bool);

    /**
     * @notice Gets the debt manager contract
     * @return IDebtManager instance
     */
    function getDebtManager() external view returns (IDebtManager);

    /**
     * @notice Prepares a safe for liquidation by canceling any pending withdrawals
     * @dev Only callable by the DebtManager
     * @param safe Address of the EtherFi Safe being liquidated
     */
    function preLiquidate(address safe) external;

    /**
     * @notice Executes post-liquidation logic to transfer tokens to the liquidator
     * @dev Only callable by the DebtManager after a successful liquidation
     * @param safe Address of the EtherFi Safe being liquidated
     * @param liquidator Address that will receive the liquidated tokens
     * @param tokensToSend Array of token data with amounts to send to the liquidator
     */
    function postLiquidate(address safe, address liquidator, IDebtManager.LiquidationTokenData[] memory tokensToSend) external;

    /**
     * @notice Gets the settlement dispatcher address
     * @dev The settlement dispatcher processes transactions in debit mode
     * @return The address of the settlement dispatcher contract
     */
    function getSettlementDispatcher() external view returns (address);

    /**
     * @notice Gets the cashback percentage and split percentage for a safe
     * @dev Returns the tier-based cashback percentage and safe's split configuration
     * @param safe Address of the EtherFi Safe
     * @return Cashback percentage in basis points (100 = 1%)
     * @return Split percentage to safe in basis points (5000 = 50%)
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
}
