// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode, SafeTiers } from "../../interfaces/ICashModule.sol";
import { SpendingLimit } from "../../libraries/SpendingLimitLib.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";

/**
 * @title CashEventEmitter
 * @author ether.fi
 * @notice Contract responsible for emitting events related to the ether.fi Cash module
 * @dev Implements upgradeable proxy pattern and access control for event emission
 */
contract CashEventEmitter is UpgradeableProxy {
    /**
     * @notice Address of the authorized Cash Module contract
     */
    address public immutable cashModule;

    /**
     * @notice Thrown when a function is called by an account other than the Cash Module
     */
    error OnlyCashModule();

    /**
     * @notice Initializes the contract with the Cash Module address
     * @dev Cannot be called again after deployment (UUPS pattern)
     * @param _cashModule Address of the Cash Module contract
     */
    constructor(address _cashModule) {
        cashModule = _cashModule;
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy functionality with role registry
     * @dev Can only be called once due to initializer modifier
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Emitted when a withdrawal is requested
     * @param safe Address of the safe requesting the withdrawal
     * @param tokens Array of token addresses to withdraw
     * @param amounts Array of token amounts to withdraw
     * @param recipient Address to receive the withdrawn tokens
     * @param finalizeTimestamp Timestamp when the withdrawal can be finalized
     */
    event WithdrawalRequested(address indexed safe, address[] tokens, uint256[] amounts, address indexed recipient, uint256 finalizeTimestamp);
    
    /**
     * @notice Emitted when a withdrawal amount is updated
     * @param safe Address of the safe updating the withdrawal
     * @param token Address of the token being updated
     * @param amount New withdrawal amount
     */
    event WithdrawalAmountUpdated(address indexed safe, address indexed token, uint256 amount);
    
    /**
     * @notice Emitted when a withdrawal is cancelled
     * @param safe Address of the safe cancelling the withdrawal
     * @param tokens Array of token addresses that were to be withdrawn
     * @param amounts Array of token amounts that were to be withdrawn
     * @param recipient Address that was to receive the withdrawn tokens
     */
    event WithdrawalCancelled(address indexed safe, address[] tokens, uint256[] amounts, address indexed recipient);
    
    /**
     * @notice Emitted when a withdrawal is processed
     * @param safe Address of the safe processing the withdrawal
     * @param tokens Array of token addresses being withdrawn
     * @param amounts Array of token amounts being withdrawn
     * @param recipient Address receiving the withdrawn tokens
     */
    event WithdrawalProcessed(address indexed safe, address[] tokens, uint256[] amounts, address indexed recipient);
    
    /**
     * @notice Emitted when debt is repaid to the debt manager
     * @param safe Address of the safe repaying the debt
     * @param token Address of the token used to repay
     * @param debtAmount Amount of debt repaid in token units
     * @param debtAmountInUsd USD value of the debt repaid
     */
    event RepayDebtManager(address indexed safe, address indexed token, uint256 debtAmount, uint256 debtAmountInUsd);
    
    /**
     * @notice Emitted when a spending limit is changed
     * @param safe Address of the safe changing the spending limit
     * @param oldLimit Previous spending limit configuration
     * @param newLimit New spending limit configuration
     */
    event SpendingLimitChanged(address indexed safe, SpendingLimit oldLimit, SpendingLimit newLimit);
    
    /**
     * @notice Emitted when the operational mode of a safe is changed
     * @param safe Address of the safe changing modes
     * @param prevMode Previous operational mode
     * @param newMode New operational mode
     * @param incomingModeStartTime Timestamp when the new mode takes effect
     */
    event ModeSet(address indexed safe, Mode prevMode, Mode newMode, uint256 incomingModeStartTime);
    
    /**
     * @notice Emitted when tokens are spent from a safe
     * @param safe Address of the safe spending the tokens
     * @param token Address of the token being spent
     * @param amount Amount of tokens being spent
     * @param amountInUsd USD value of the tokens being spent
     * @param mode Operational mode in which the spending occurs
     */
    event Spend(address indexed safe, address indexed token, uint256 amount, uint256 amountInUsd, Mode mode);
    
    /**
     * @notice Emitted when cashback is calculated and potentially distributed
     * @param safe Address of the safe receiving cashback
     * @param spender Address of the spender who initiated the transaction
     * @param spendingInUsd USD value of the spending that generated the cashback
     * @param cashbackToken Address of the token used for cashback
     * @param cashbackAmountToSafe Amount of cashback tokens sent to the safe
     * @param cashbackInUsdToSafe USD value of cashback sent to the safe
     * @param cashbackAmountToSpender Amount of cashback tokens sent to the spender
     * @param cashbackInUsdToSpender USD value of cashback sent to the spender
     * @param paid Whether the cashback was successfully paid
     */
    event Cashback(address indexed safe, address indexed spender, uint256 spendingInUsd, address cashbackToken, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool indexed paid);
    
    /**
     * @notice Emitted when pending cashback is cleared
     * @param safe Address of the safe with pending cashback
     * @param recipient Address receiving the cashback
     * @param cashbackToken Address of the token used for cashback
     * @param cashbackAmount Amount of cashback tokens paid
     * @param cashbackInUsd USD value of the cashback paid
     */
    event PendingCashbackCleared(address indexed safe, address indexed recipient, address cashbackToken, uint256 cashbackAmount, uint256 cashbackInUsd);
    
    /**
     * @notice Emitted when safe tiers are set for multiple safes
     * @param safes Array of safe addresses
     * @param tiers Array of tier configurations corresponding to each safe
     */
    event SafeTiersSet(address[] safes, SafeTiers[] tiers);
    
    /**
     * @notice Emitted when cashback percentages for tiers are set
     * @param tiers Array of tiers being configured
     * @param cashbackPercentages Array of cashback percentages corresponding to each tier
     */
    event TierCashbackPercentageSet(SafeTiers[] tiers, uint256[] cashbackPercentages);
    
    /**
     * @notice Emitted when the cashback split percentage for a safe is set
     * @param safe Address of the safe
     * @param oldSplitInBps Previous split percentage in basis points
     * @param newSplitInBps New split percentage in basis points
     */
    event CashbackSplitToSafeBpsSet(address safe, uint256 oldSplitInBps, uint256 newSplitInBps);
    
    /**
     * @notice Emitted when system delays are set
     * @param withdrawalDelay Delay period for withdrawals
     * @param spendingLimitDelay Delay period for spending limit changes
     * @param modeDelay Delay period for mode changes
     */
    event DelaysSet(uint64 withdrawalDelay, uint64 spendingLimitDelay, uint64 modeDelay);
    
    /**
     * @notice Emitted when withdrawal recipients are configured
     * @param safe Address of the safe
     * @param withdrawRecipients Array of recipient addresses
     * @param shouldWhitelist Array of boolean flags indicating whether each recipient should be whitelisted
     */
    event WithdrawRecipientsConfigured(address safe, address[] withdrawRecipients, bool[] shouldWhitelist);

    /**
     * @notice Emits the WithdrawRecipientsConfigured event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param withdrawRecipients Array of recipient addresses
     * @param shouldWhitelist Array of boolean flags
     */
    function emitConfigureWithdrawRecipients(address safe, address[] calldata withdrawRecipients, bool[] calldata shouldWhitelist) external onlyCashModule {
        emit WithdrawRecipientsConfigured(safe, withdrawRecipients, shouldWhitelist);
    }

    /**
     * @notice Emits the SafeTiersSet event
     * @dev Can only be called by the Cash Module
     * @param safes Array of safe addresses
     * @param safeTiers Array of tier configurations
     */
    function emitSetSafeTiers(address[] memory safes, SafeTiers[] memory safeTiers) external onlyCashModule {
        emit SafeTiersSet(safes, safeTiers);
    }

    /**
     * @notice Emits the TierCashbackPercentageSet event
     * @dev Can only be called by the Cash Module
     * @param safeTiers Array of tiers
     * @param cashbackPercentages Array of cashback percentages
     */
    function emitSetTierCashbackPercentage(SafeTiers[] memory safeTiers, uint256[] memory cashbackPercentages) external onlyCashModule {
        emit TierCashbackPercentageSet(safeTiers, cashbackPercentages);
    }

    /**
     * @notice Emits the CashbackSplitToSafeBpsSet event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param oldSplitInBps Previous split percentage
     * @param newSplitInBps New split percentage
     */
    function emitSetCashbackSplitToSafeBps(address safe, uint256 oldSplitInBps, uint256 newSplitInBps) external onlyCashModule {
        emit CashbackSplitToSafeBpsSet(safe, oldSplitInBps, newSplitInBps);
    }

    /**
     * @notice Emits the DelaysSet event
     * @dev Can only be called by the Cash Module
     * @param withdrawalDelay Delay period for withdrawals
     * @param spendingLimitDelay Delay period for spending limit changes
     * @param modeDelay Delay period for mode changes
     */
    function emitSetDelays(uint64 withdrawalDelay, uint64 spendingLimitDelay, uint64 modeDelay) external onlyCashModule {
        emit DelaysSet(withdrawalDelay, spendingLimitDelay, modeDelay);
    }

    /**
     * @notice Emits the PendingCashbackCleared event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param recipient Address receiving the cashback
     * @param cashbackToken Address of the cashback token
     * @param cashbackAmount Amount of cashback tokens
     * @param cashbackInUsd USD value of the cashback
     */
    function emitPendingCashbackClearedEvent(address safe, address recipient, address cashbackToken, uint256 cashbackAmount, uint256 cashbackInUsd) external onlyCashModule {
        emit PendingCashbackCleared(safe, recipient, cashbackToken, cashbackAmount, cashbackInUsd);
    }

    /**
     * @notice Emits the Cashback event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param spender Address of the spender
     * @param spendingInUsd USD value of the spending
     * @param cashbackToken Address of the cashback token
     * @param cashbackAmountToSafe Amount to the safe
     * @param cashbackInUsdToSafe USD value to the safe
     * @param cashbackAmountToSpender Amount to the spender
     * @param cashbackInUsdToSpender USD value to the spender
     * @param paid Whether the cashback was paid
     */
    function emitCashbackEvent(address safe, address spender, uint256 spendingInUsd, address cashbackToken, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) external onlyCashModule {
        emit Cashback(safe, spender, spendingInUsd, cashbackToken, cashbackAmountToSafe, cashbackInUsdToSafe, cashbackAmountToSpender, cashbackInUsdToSpender, paid);
    }

    /**
     * @notice Emits the Spend event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param token Address of the token
     * @param amount Amount of tokens
     * @param amountInUsd USD value
     * @param mode Operational mode
     */
    function emitSpend(address safe, address token, uint256 amount, uint256 amountInUsd, Mode mode) external onlyCashModule {
        emit Spend(safe, token, amount, amountInUsd, mode);
    }

    /**
     * @notice Emits the ModeSet event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param prevMode Previous mode
     * @param newMode New mode
     * @param incomingModeStartTime Start time for the new mode
     */
    function emitSetMode(address safe, Mode prevMode, Mode newMode, uint256 incomingModeStartTime) external onlyCashModule {
        emit ModeSet(safe, prevMode, newMode, incomingModeStartTime);
    }

    /**
     * @notice Emits the WithdrawalRequested event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param tokens Array of token addresses
     * @param amounts Array of token amounts
     * @param recipient Recipient address
     * @param finalizeTimestamp Finalization timestamp
     */
    function emitWithdrawalRequested(address safe, address[] memory tokens, uint256[] memory amounts, address recipient, uint256 finalizeTimestamp) external onlyCashModule {
        emit WithdrawalRequested(safe, tokens, amounts, recipient, finalizeTimestamp);
    }

    /**
     * @notice Emits the WithdrawalAmountUpdated event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param token Token address
     * @param amount New amount
     */
    function emitWithdrawalAmountUpdated(address safe, address token, uint256 amount) external onlyCashModule {
        emit WithdrawalAmountUpdated(safe, token, amount);
    }

    /**
     * @notice Emits the WithdrawalCancelled event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param tokens Array of token addresses
     * @param amounts Array of token amounts
     * @param recipient Recipient address
     */
    function emitWithdrawalCancelled(address safe, address[] memory tokens, uint256[] memory amounts, address recipient) external onlyCashModule {
        emit WithdrawalCancelled(safe, tokens, amounts, recipient);
    }

    /**
     * @notice Emits the WithdrawalProcessed event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param tokens Array of token addresses
     * @param amounts Array of token amounts
     * @param recipient Recipient address
     */
    function emitWithdrawalProcessed(address safe, address[] memory tokens, uint256[] memory amounts, address recipient) external onlyCashModule {
        emit WithdrawalProcessed(safe, tokens, amounts, recipient);
    }

    /**
     * @notice Emits the RepayDebtManager event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param token Token address
     * @param amount Amount repaid
     * @param amountInUsd USD value repaid
     */
    function emitRepayDebtManager(address safe, address token, uint256 amount, uint256 amountInUsd) external onlyCashModule {
        emit RepayDebtManager(safe, token, amount, amountInUsd);
    }

    /**
     * @notice Emits the SpendingLimitChanged event
     * @dev Can only be called by the Cash Module
     * @param safe Address of the safe
     * @param oldLimit Previous spending limit
     * @param newLimit New spending limit
     */
    function emitSpendingLimitChanged(address safe, SpendingLimit memory oldLimit, SpendingLimit memory newLimit) external onlyCashModule {
        emit SpendingLimitChanged(safe, oldLimit, newLimit);
    }

    /**
     * @dev Internal function to verify caller is the Cash Module
     * @custom:throws OnlyCashModule If the caller is not the Cash Module
     */
    function _onlyCashModule() private view {
        if (cashModule != msg.sender) revert OnlyCashModule();
    }

    /**
     * @dev Modifier to restrict function access to the Cash Module only
     */
    modifier onlyCashModule() {
        _onlyCashModule();
        _;
    }
}