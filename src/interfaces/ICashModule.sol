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
    uint256 incomingCreditModeStartTime;
}

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
    /// @notice Spend limit for the user
    SpendingLimit spendingLimit;
    /// @notice Impending withdrawal request for the user
    WithdrawalRequest pendingWithdrawalRequest;
    /// @notice User's chosen mode
    Mode mode;
    /// @notice Map for deduplication of spends
    mapping(bytes32 txId => bool cleared) transactionCleared;
    uint256 incomingCreditModeStartTime;
    EnumerableSetLib.AddressSet withdrawRecipients;
    SafeTiers safeTier;
    uint256 cashbackSplitToSafePercentage;
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

    function preLiquidate(address safe) external;

    function postLiquidate(address safe, address liquidator, IDebtManager.LiquidationTokenData[] memory tokensToSend) external;

    function getSettlementDispatcher() external view returns (address);

    function getSafeCashbackPercentageAndSplit(address safe) external view returns (uint256, uint256);

    function etherFiDataProvider() external view returns (IEtherFiDataProvider);

    function getPendingCashback(address account) external view returns (uint256);
}
