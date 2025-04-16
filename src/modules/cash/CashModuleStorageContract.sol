// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ICashEventEmitter } from "../../interfaces/ICashEventEmitter.sol";
import { Mode, SafeCashConfig, SafeData, SafeTiers, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { ICashbackDispatcher } from "../../interfaces/ICashbackDispatcher.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";
import { CashVerificationLib } from "../../libraries/CashVerificationLib.sol";
import { SignatureUtils } from "../../libraries/SignatureUtils.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title CashModule
 * @notice Cash features for EtherFi Safe accounts
 * @author ether.fi
 */
contract CashModuleStorageContract is UpgradeableProxy, ModuleBase {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using SpendingLimitLib for SpendingLimit;
    using MessageHashUtils for bytes32;
    using ArrayDeDupLib for address[];

    /**
     * @dev Storage structure for CashModule using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.CashModuleStorage
     */
    struct CashModuleStorage {
        /// @notice Safe Cash Config for each safe
        mapping(address safe => SafeCashConfig cashConfig) safeCashConfig;
        /// @notice Instance of the DebtManager for borrowing and repayment operations
        IDebtManager debtManager;
        /// @notice Address of the SettlementDispatcher for Reap 
        address settlementDispatcherReap;
        /// @notice Delay in seconds before a withdrawal request can be finalized
        uint64 withdrawalDelay;
        /// @notice Delay in seconds before spending limit changes take effect
        uint64 spendLimitDelay;
        /// @notice Delay in seconds before a mode change (particularly to Credit mode) takes effect
        uint64 modeDelay;
        /// @notice Mapping of safe tiers to cashback percentages in basis points (100 = 1%)
        mapping(SafeTiers tier => uint256 cashbackPercentage) tierCashbackPercentage;
        /// @notice Tracks pending cashback amounts in USD for each account (safe or spender)
        mapping(address account => uint256 pendingCashback) pendingCashbackInUsd;
        /// @notice Reference to the cashback dispatcher contract that processes cashback rewards
        ICashbackDispatcher cashbackDispatcher;
        /// @notice Reference to the event emitter contract that standardizes event emissions
        ICashEventEmitter cashEventEmitter;
        /// @notice Address of cash module setters contract
        address cashModuleSetters;
        /// @notice Cashback percentage for referrer in bps
        uint64 referrerCashbackPercentageInBps;
        /// @notice Address of the SettlementDispatcher for Rain 
        address settlementDispatcherRain;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashModuleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CashModuleStorageLocation = 0xe000c7adec5855bcf51f74b73aa86172d0a325bc54c3f73cb406d259df90ea00;

    /// @notice Role identifier for EtherFi wallet access control
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    /// @notice Role identifier for Cash Moudle controller access control
    bytes32 public constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");
    /// @notice Limit for maximum cashback percentage at 10%
    uint256 public constant MAX_CASHBACK_PERCENTAGE = 1000; // 10%
    /// @notice 100% in bps
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10_000;

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

    /// @notice Error thrown when a recipient address is set to zero
    error RecipientCannotBeAddressZero();

    /// @notice Error thrown when a function restricted to the Cash Module Controller is called by another address
    error OnlyCashModuleController();

    /// @notice Error thrown when attempting to process a withdrawal before the delay period has elapsed
    error CannotWithdrawYet();

    /// @notice Error thrown when transaction or withdrawal signatures are invalid or unauthorized
    error InvalidSignatures();

    /// @notice Error thrown when attempting to set a mode that is already active
    error ModeAlreadySet();

    /// @notice Error thrown when a function restricted to the Debt Manager is called by another address
    error OnlyDebtManager();

    /// @notice Error thrown when trying to change a safe's tier to its current tier
    /// @param index The index of the safe for which tier that is the same
    error AlreadyInSameTier(uint256 index);

    /// @notice Error thrown when a cashback percentage exceeds the maximum allowed value
    error CashbackPercentageGreaterThanMaxAllowed();

    /// @notice Error thrown when attempting to set a split ratio that is identical to the current split
    error SplitAlreadyTheSame();

    /// @notice Error thrown when trying to use multiple tokens in credit mode
    error OnlyOneTokenAllowedInCreditMode();

    /// @notice Error thrown when Settlement Dispatcher address is not set for the bin sponsor
    error SettlementDispatcherNotSetForBinSponsor();

    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) { 
        _disableInitializers();
    }

    /**
     * @dev Returns the storage struct for CashModule
     * @return $ Reference to the CashModuleStorage struct
     */
    function _getCashModuleStorage() internal pure returns (CashModuleStorage storage $) {
        assembly {
            $.slot := CashModuleStorageLocation
        }
    }

    /**
     * @notice Gets the debt manager contract
     * @return IDebtManager instance
     */
    function _getDebtManager() internal view returns (IDebtManager) {
        return _getCashModuleStorage().debtManager;
    }

    /**
     * @dev Cancels pending withdrawal requests for a Safe
     * @param safe Address of the EtherFi Safe
     */
    function _cancelOldWithdrawal(address safe) internal {
        ICashEventEmitter eventEmitter = _getCashModuleStorage().cashEventEmitter;
        SafeCashConfig storage safeCashConfig = _getCashModuleStorage().safeCashConfig[safe];
        if (safeCashConfig.pendingWithdrawalRequest.tokens.length > 0) {
            eventEmitter.emitWithdrawalCancelled(safe, safeCashConfig.pendingWithdrawalRequest.tokens, safeCashConfig.pendingWithdrawalRequest.amounts, safeCashConfig.pendingWithdrawalRequest.recipient);
            delete safeCashConfig.pendingWithdrawalRequest;
        }
    }

    /**
     * @dev Updates withdrawal request if necessary based on available balance
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to update
     * @param amount Amount being processed
     * @custom:throws InsufficientBalance if there is not enough balance for the operation
     */
    function _updateWithdrawalRequestIfNecessary(address safe, address token, uint256 amount) internal {
        ICashEventEmitter eventEmitter = _getCashModuleStorage().cashEventEmitter;
        SafeCashConfig storage safeCashConfig = _getCashModuleStorage().safeCashConfig[safe];
        uint256 balance = IERC20(token).balanceOf(safe);

        if (amount > balance) revert InsufficientBalance();

        uint256 len = safeCashConfig.pendingWithdrawalRequest.tokens.length;
        uint256 tokenIndex = len;
        for (uint256 i = 0; i < len;) {
            if (safeCashConfig.pendingWithdrawalRequest.tokens[i] == token) {
                tokenIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // If the token does not exist in withdrawal request, return
        if (tokenIndex == len) return;

        if (amount + safeCashConfig.pendingWithdrawalRequest.amounts[tokenIndex] > balance) {
            safeCashConfig.pendingWithdrawalRequest.amounts[tokenIndex] = balance - amount;

            eventEmitter.emitWithdrawalAmountUpdated(safe, token, balance - amount);
        }
    }

    /**
     * @dev Checks if a token is a valid borrow token
     * @param debtManager Reference to the debt manager contract
     * @param token Address of the token to check
     * @return Boolean indicating if the token is a borrow token
     */
    function _isBorrowToken(IDebtManager debtManager, address token) internal view returns (bool) {
        return debtManager.isBorrowToken(token);
    }

    /**
     * @dev Modifier to ensure caller has the EtherFi wallet role
     * @custom:throws OnlyEtherFiWallet if caller does not have the role
     */
    modifier onlyEtherFiWallet() {
        if (!roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();
        _;
    }

    /**
     * @notice Updates the current mode of a safe if a pending mode change is ready
     * @dev Checks if a pending credit mode change has passed its delay and applies it
     * @param $ Storage reference to the SafeCashConfig for the safe
     */
    function _setCurrentMode(SafeCashConfig storage $) internal {
        if ($.incomingCreditModeStartTime != 0 && block.timestamp > $.incomingCreditModeStartTime) {
            $.mode = Mode.Credit;
            delete $.incomingCreditModeStartTime;
        }
    }

    /**
     * @notice Processes a pending withdrawal request for a Safe after delay period
     * @dev Transfers tokens to the designated recipient if the finalize time has passed
     * @param safe Address of the EtherFi Safe processing the withdrawal
     * @custom:throws CannotWithdrawYet if the withdrawal delay period has not elapsed
     */
    function _processWithdrawal(address safe) internal {
        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[safe];

        if ($.pendingWithdrawalRequest.finalizeTime > block.timestamp) revert CannotWithdrawYet();
        address recipient = $.pendingWithdrawalRequest.recipient;
        uint256 len = $.pendingWithdrawalRequest.tokens.length;

        address[] memory to = new address[](len);
        bytes[] memory data = new bytes[](len);

        for (uint256 i = 0; i < len;) {
            to[i] = $.pendingWithdrawalRequest.tokens[i];
            data[i] = abi.encodeWithSelector(IERC20.transfer.selector, recipient, $.pendingWithdrawalRequest.amounts[i]);

            unchecked {
                ++i;
            }
        }

        _getCashModuleStorage().cashEventEmitter.emitWithdrawalProcessed(safe, $.pendingWithdrawalRequest.tokens, $.pendingWithdrawalRequest.amounts, recipient);
        delete $.pendingWithdrawalRequest;

        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](len), data);
    }
}
