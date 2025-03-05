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
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";
import { CashVerificationLib } from "../../libraries/CashVerificationLib.sol";
import { EnumerableAddressWhitelistLib } from "../../libraries/EnumerableAddressWhitelistLib.sol";
import { SignatureUtils } from "../../libraries/SignatureUtils.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title CashModule
 * @notice Cash features for EtherFi Safe accounts
 * @author ether.fi
 */
contract CashModule is UpgradeableProxy, ModuleBase {
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
        /// @notice Address of the SettlementDispatcher that processes debit mode transactions
        address settlementDispatcher;
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
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashModuleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CashModuleStorageLocation = 0xe000c7adec5855bcf51f74b73aa86172d0a325bc54c3f73cb406d259df90ea00;

    /// @notice Role identifier for EtherFi wallet access control
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    bytes32 public constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");
    uint256 public constant MAX_CASHBACK_PERCENTAGE = 1000; // 10%
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

    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) { }

    /**
     * @notice Initializes the CashModule contract
     * @dev Sets up the role registry, debt manager, settlement dispatcher, and data providers
     * @param _roleRegistry Address of the role registry contract
     * @param _debtManager Address of the debt manager contract
     * @param _settlementDispatcher Address of the settlement dispatcher
     */
    function initialize(address _roleRegistry, address _debtManager, address _settlementDispatcher, address _cashbackDispatcher, address _cashEventEmitter) external {
        __UpgradeableProxy_init(_roleRegistry);

        CashModuleStorage storage $ = _getCashModuleStorage();

        $.debtManager = IDebtManager(_debtManager);

        if (_settlementDispatcher == address(0) || _cashbackDispatcher == address(0) || _cashEventEmitter == address(0)) revert InvalidInput();
        $.settlementDispatcher = _settlementDispatcher;
        $.cashbackDispatcher = ICashbackDispatcher(_cashbackDispatcher);
        $.cashEventEmitter = ICashEventEmitter(_cashEventEmitter);

        $.withdrawalDelay = 60; // 1 min
        $.spendLimitDelay = 3600; // 1 hour
        $.modeDelay = 60; // 1 min
    }

    /**
     * @notice Sets up a new Safe's Cash Module with initial configuration
     * @dev Creates default spending limits and sets initial mode to Debit with 50% cashback split
     * @param data The encoded initialization data containing daily limit, monthly limit, and timezone offset
     */
    function setupModule(bytes calldata data) external override onlyEtherFiSafe(msg.sender) {
        (uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, int256 timezoneOffset) = abi.decode(data, (uint256, uint256, int256));

        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[msg.sender];
        $.spendingLimit.initialize(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);
        $.mode = Mode.Debit;
        $.cashbackSplitToSafePercentage = 5000; // 50%
    }

    /**
     * @notice Sets the tier for one or more safes
     * @dev Assigns tiers which determine cashback percentages
     * @param safes Array of safe addresses to update
     * @param tiers Array of tiers to assign to the corresponding safe addresses
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws OnlyEtherFiSafe if any address is not a valid EtherFi Safe
     * @custom:throws AlreadyInSameTier if a safe is already in the specified tier
     */
    function setSafeTier(address[] memory safes, SafeTiers[] memory tiers) external onlyEtherFiWallet {
        CashModuleStorage storage $ = _getCashModuleStorage();

        uint256 len = safes.length;
        if (len != tiers.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len;) {
            if (!etherFiDataProvider.isEtherFiSafe(safes[i])) revert OnlyEtherFiSafe();
            if ($.safeCashConfig[safes[i]].safeTier == tiers[i]) revert AlreadyInSameTier(i);

            $.safeCashConfig[safes[i]].safeTier = tiers[i];
            unchecked {
                ++i;
            }
        }

        $.cashEventEmitter.emitSetSafeTiers(safes, tiers);
    }

    /**
     * @notice Sets the cashback percentage for different tiers
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param tiers Array of tiers to configure
     * @param cashbackPercentages Array of cashback percentages in basis points (100 = 1%)
     * @custom:throws OnlyCashModuleController if caller doesn't have the controller role
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws CashbackPercentageGreaterThanMaxAllowed if any percentage exceeds the maximum allowed
     */
    function setTierCashbackPercentage(SafeTiers[] memory tiers, uint256[] memory cashbackPercentages) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();

        CashModuleStorage storage $ = _getCashModuleStorage();

        uint256 len = tiers.length;
        if (len != cashbackPercentages.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len;) {
            if (cashbackPercentages[i] > MAX_CASHBACK_PERCENTAGE) revert CashbackPercentageGreaterThanMaxAllowed();
            $.tierCashbackPercentage[tiers[i]] = cashbackPercentages[i];
            unchecked {
                ++i;
            }
        }

        $.cashEventEmitter.emitSetTierCashbackPercentage(tiers, cashbackPercentages);
    }

    /**
     * @notice Sets the percentage of cashback that goes to the safe (versus the spender)
     * @dev Can only be called by the safe itself with a valid admin signature
     * @param safe Address of the safe to configure
     * @param splitInBps Percentage in basis points to allocate to the safe (10000 = 100%)
     * @param signer Address of the safe admin signing the transaction
     * @param signature Signature from the signer authorizing this change
     * @custom:throws SplitAlreadyTheSame if the new split is the same as the current one
     * @custom:throws InvalidInput if the split percentage exceeds 100%
     */
    function setCashbackSplitToSafeBps(address safe, uint256 splitInBps, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        CashModuleStorage storage $ = _getCashModuleStorage();

        if (splitInBps == $.safeCashConfig[safe].cashbackSplitToSafePercentage) revert SplitAlreadyTheSame();
        if (splitInBps > HUNDRED_PERCENT_IN_BPS) revert InvalidInput();

        CashVerificationLib.verifySetCashbackSplitToSafePercentage(safe, signer, _useNonce(safe), splitInBps, signature);

        $.cashEventEmitter.emitSetCashbackSplitToSafeBps(safe, $.safeCashConfig[safe].cashbackSplitToSafePercentage, splitInBps);
        $.safeCashConfig[safe].cashbackSplitToSafePercentage = splitInBps;
    }

    /**
     * @notice Gets the cashback percentage and split percentage for a safe
     * @dev Returns the tier-based cashback percentage and safe's split configuration
     * @param safe Address of the EtherFi Safe
     * @return Cashback percentage in basis points (100 = 1%)
     * @return Split percentage to safe in basis points (5000 = 50%)
     */
    function getSafeCashbackPercentageAndSplit(address safe) public view onlyEtherFiSafe(safe) returns (uint256, uint256) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        return ($.tierCashbackPercentage[$.safeCashConfig[safe].safeTier], $.safeCashConfig[safe].cashbackSplitToSafePercentage);
    }

    /**
     * @notice Sets the time delays for withdrawals, spending limit changes, and mode changes
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param withdrawalDelay Delay in seconds before a withdrawal can be finalized
     * @param spendLimitDelay Delay in seconds before spending limit changes take effect
     * @param modeDelay Delay in seconds before a mode change takes effect
     * @custom:throws OnlyCashModuleController if caller doesn't have the controller role
     */
    function setDelays(uint64 withdrawalDelay, uint64 spendLimitDelay, uint64 modeDelay) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();
        CashModuleStorage storage $ = _getCashModuleStorage();

        $.withdrawalDelay = withdrawalDelay;
        $.spendLimitDelay = spendLimitDelay;
        $.modeDelay = modeDelay;

        $.cashEventEmitter.emitSetDelays(withdrawalDelay, spendLimitDelay, modeDelay);
    }

    /**
     * @notice Gets the current delay settings for the module
     * @return withdrawalDelay Delay in seconds before a withdrawal can be finalized
     * @return spendLimitDelay Delay in seconds before spending limit changes take effect
     * @return modeDelay Delay in seconds before a mode change takes effect
     */
    function getDelays() external view returns (uint64, uint64, uint64) {
        CashModuleStorage storage $ = _getCashModuleStorage();

        return ($.withdrawalDelay, $.spendLimitDelay, $.modeDelay);
    }

    /**
     * @notice Gets the pending cashback amount for an account in USD
     * @dev Returns the amount of cashback waiting to be claimed
     * @param account Address of the account (safe or spender)
     * @return Pending cashback amount in USD
     */
    function getPendingCashback(address account) external view returns (uint256) {
        return _getCashModuleStorage().pendingCashbackInUsd[account];
    }

    /**
     * @notice Gets the settlement dispatcher address
     * @dev The settlement dispatcher processes transactions in debit mode
     * @return The address of the settlement dispatcher
     */
    function getSettlementDispatcher() external view returns (address) {
        return _getCashModuleStorage().settlementDispatcher;
    }

    /**
     * @notice Sets the operating mode for a safe
     * @dev Switches between Debit and Credit modes, with possible delay for Credit mode
     * @param safe Address of the EtherFi Safe
     * @param mode The target mode (Debit or Credit)
     * @param signer Address of the safe admin signing the transaction
     * @param signature Signature from the signer authorizing this mode change
     * @custom:throws ModeAlreadySet if the safe is already in the requested mode
     */
    function setMode(address safe, Mode mode, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        CashModuleStorage storage $ = _getCashModuleStorage();

        _setCurrentMode($.safeCashConfig[safe]);

        if (mode == $.safeCashConfig[safe].mode) revert ModeAlreadySet();

        CashVerificationLib.verifySetModeSig(safe, signer, _useNonce(safe), mode, signature);

        if ($.modeDelay == 0) {
            $.cashEventEmitter.emitSetMode(safe, $.safeCashConfig[safe].mode, mode, block.timestamp);
            // If delay = 0, just set the value
            $.safeCashConfig[safe].mode = mode;
        } else {
            // If delay != 0, debit to credit mode should incur delay
            if (mode == Mode.Credit) {
                $.safeCashConfig[safe].incomingCreditModeStartTime = block.timestamp + $.modeDelay;
                $.cashEventEmitter.emitSetMode(safe, Mode.Debit, Mode.Credit, $.safeCashConfig[safe].incomingCreditModeStartTime);
            } else {
                // If mode is debit, no problem, just set the mode
                $.safeCashConfig[safe].incomingCreditModeStartTime = 0;
                $.safeCashConfig[safe].mode = mode;
                $.cashEventEmitter.emitSetMode(safe, Mode.Credit, Mode.Debit, block.timestamp);
            }
        }
    }

    /**
     * @notice Gets the current operating mode of a safe
     * @dev Considers pending mode changes that have passed their delay
     * @param safe Address of the EtherFi Safe
     * @return The current operating mode (Debit or Credit)
     */
    function getMode(address safe) external view returns (Mode) {
        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[safe];

        if ($.incomingCreditModeStartTime != 0 && block.timestamp > $.incomingCreditModeStartTime) return Mode.Credit;
        return $.mode;
    }

    /**
     * @notice Gets the timestamp when a pending credit mode change will take effect
     * @dev Returns 0 if no pending change or if the safe uses debit mode
     * @param safe Address of the EtherFi Safe
     * @return Timestamp when credit mode will take effect, or 0 if not applicable
     */
    function incomingCreditModeStartTime(address safe) external view returns (uint256) {
        return _getCashModuleStorage().safeCashConfig[safe].incomingCreditModeStartTime;
    }

    /**
     * @notice Updates the spending limits for a safe
     * @dev Can only be called by the safe itself with a valid admin signature
     * @param safe Address of the EtherFi Safe
     * @param dailyLimitInUsd New daily spending limit in USD
     * @param monthlyLimitInUsd New monthly spending limit in USD
     * @param signer Address of the safe admin signing the transaction
     * @param signature Signature from the signer authorizing this update
     */
    function updateSpendingLimit(address safe, uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        CashVerificationLib.verifyUpdateSpendingLimitSig(safe, signer, _useNonce(safe), dailyLimitInUsd, monthlyLimitInUsd, signature);
        _updateSpendingLimit(safe, dailyLimitInUsd, monthlyLimitInUsd);
    }

    /**
     * @notice Internal function to update spending limits
     * @dev Updates the limits and emits an event with old and new values
     * @param safe Address of the EtherFi Safe
     * @param dailyLimitInUsd New daily spending limit in USD
     * @param monthlyLimitInUsd New monthly spending limit in USD
     */
    function _updateSpendingLimit(address safe, uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();

        (SpendingLimit memory oldLimit, SpendingLimit memory newLimit) = $.safeCashConfig[safe].spendingLimit.updateSpendingLimit(dailyLimitInUsd, monthlyLimitInUsd, _getCashModuleStorage().spendLimitDelay);
        $.cashEventEmitter.emitSpendingLimitChanged(safe, oldLimit, newLimit);
    }

    /**
     * @notice Prepares a safe for liquidation by canceling any pending withdrawals
     * @dev Only callable by the DebtManager
     * @param safe Address of the EtherFi Safe being liquidated
     * @custom:throws OnlyDebtManager if called by any address other than the DebtManager
     */
    function preLiquidate(address safe) external {
        if (msg.sender != address(getDebtManager())) revert OnlyDebtManager();
        _cancelOldWithdrawal(safe);
    }

    /**
     * @notice Executes post-liquidation logic to transfer tokens to the liquidator
     * @dev Only callable by the DebtManager after a successful liquidation
     * @param safe Address of the EtherFi Safe being liquidated
     * @param liquidator Address that will receive the liquidated tokens
     * @param tokensToSend Array of token data with amounts to send to the liquidator
     * @custom:throws OnlyDebtManager if called by any address other than the DebtManager
     */
    function postLiquidate(address safe, address liquidator, IDebtManager.LiquidationTokenData[] memory tokensToSend) external {
        if (msg.sender != address(getDebtManager())) revert OnlyDebtManager();

        uint256 len = tokensToSend.length;
        address[] memory to = new address[](len);
        bytes[] memory data = new bytes[](len);
        uint256 counter = 0;

        for (uint256 i = 0; i < len;) {
            if (tokensToSend[i].amount > 0) {
                to[i] = tokensToSend[i].token;
                data[i] = abi.encodeWithSelector(IERC20.transfer.selector, liquidator, tokensToSend[i].amount);
                unchecked {
                    ++counter;
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(to, counter)
            mstore(data, counter)
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](counter), data);
    }

    /**
     * @notice Configures whitelist of approved withdrawal recipients
     * @dev Only callable by the safe itself with valid signatures
     * @param safe Address of the EtherFi Safe
     * @param withdrawRecipients Array of recipient addresses to configure
     * @param shouldWhitelist Array of boolean flags indicating whether to add or remove each recipient
     * @param signers Array of safe admin addresses signing the transaction
     * @param signatures Array of signatures from the signers
     */
    function configureWithdrawRecipients(address safe, address[] calldata withdrawRecipients, bool[] calldata shouldWhitelist, address[] calldata signers, bytes[] calldata signatures) external onlyEtherFiSafe(safe) {
        CashVerificationLib.verifyConfigureWithdrawRecipients(safe, _useNonce(safe), withdrawRecipients, shouldWhitelist, signers, signatures);

        CashModuleStorage storage $ = _getCashModuleStorage();
        EnumerableAddressWhitelistLib.configure($.safeCashConfig[safe].withdrawRecipients, withdrawRecipients, shouldWhitelist);
        $.cashEventEmitter.emitConfigureWithdrawRecipients(safe, withdrawRecipients, shouldWhitelist);
    }

    /**
     * @notice Requests a withdrawal of tokens to a whitelisted recipient
     * @dev Creates a pending withdrawal request that can be processed after the delay period
     * @dev Can only be done by the quorum of owners of the safe
     * @param safe Address of the EtherFi Safe
     * @param tokens Array of token addresses to withdraw
     * @param amounts Array of token amounts to withdraw
     * @param recipient Address to receive the withdrawn tokens (must be whitelisted)
     * @param signers Array of safe owner addresses signing the transaction
     * @param signatures Array of signatures from the safe owners
     */
    function requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, address[] calldata signers, bytes[] calldata signatures) external onlyEtherFiSafe(safe) {
        CashVerificationLib.verifyRequestWithdrawalSig(safe, _useNonce(safe), tokens, amounts, recipient, signers, signatures);
        _requestWithdrawal(safe, tokens, amounts, recipient);
    }

    /**
     * @notice Gets all whitelisted withdrawal recipients for a safe
     * @dev Returns an array of approved addresses
     * @param safe Address of the EtherFi Safe
     * @return Array of whitelisted recipient addresses
     */
    function getWithdrawRecipients(address safe) external view returns (address[] memory) {
        return _getCashModuleStorage().safeCashConfig[safe].withdrawRecipients.values();
    }

    /**
     * @notice Checks if an address is a whitelisted withdrawal recipient for a safe
     * @dev Returns true if the address is approved to receive withdrawals
     * @param safe Address of the EtherFi Safe
     * @param account Address to check
     * @return Boolean indicating if the account is whitelisted
     */
    function isWhitelistedWithdrawRecipient(address safe, address account) external view returns (bool) {
        return _getCashModuleStorage().safeCashConfig[safe].withdrawRecipients.contains(account);
    }

    /**
     * @notice Processes a pending withdrawal request after the delay period
     * @dev Executes the token transfers and clears the request
     * @param safe Address of the EtherFi Safe
     * @custom:throws CannotWithdrawYet if the withdrawal delay period hasn't passed
     */
    function processWithdrawal(address safe) public onlyEtherFiSafe(safe) {
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
     * @notice Retrieves cash configuration data for a Safe
     * @dev Only callable for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @return Data structure containing Safe cash configuration
     * @custom:throws If the address is not a valid EtherFi Safe
     */
    function getData(address safe) external view onlyEtherFiSafe(safe) returns (SafeData memory) {
        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[safe];
        SafeData memory data = SafeData({ spendingLimit: $.spendingLimit, pendingWithdrawalRequest: $.pendingWithdrawalRequest, mode: $.mode, incomingCreditModeStartTime: $.incomingCreditModeStartTime, totalCashbackEarnedInUsd: $.totalCashbackEarnedInUsd });

        return data;
    }

    /**
     * @notice Checks if a transaction has been cleared
     * @dev Only callable for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @return Boolean indicating if the transaction is cleared
     * @custom:throws If the address is not a valid EtherFi Safe
     */
    function transactionCleared(address safe, bytes32 txId) public view onlyEtherFiSafe(safe) returns (bool) {
        return _getCashModuleStorage().safeCashConfig[safe].transactionCleared[txId];
    }

    /**
     * @notice Gets the debt manager contract
     * @return IDebtManager instance
     */
    function getDebtManager() public view returns (IDebtManager) {
        return _getCashModuleStorage().debtManager;
    }

    /**
     * @notice Processes a spending transaction
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param token Address of the token to spend
     * @param amountInUsd Amount to spend in USD
     * @custom:throws TransactionAlreadyCleared if the transaction was already processed
     * @custom:throws UnsupportedToken if the token is not supported
     * @custom:throws AmountZero if the converted amount is zero
     * @custom:throws If spending would exceed limits or balances
     */
    function spend(address safe, address spender, bytes32 txId, address token, uint256 amountInUsd) external onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        IDebtManager debtManager = $.debtManager;

        if (spender == safe) revert InvalidInput();

        _setCurrentMode($$);

        if ($$.transactionCleared[txId]) revert TransactionAlreadyCleared();
        if (!_isBorrowToken(debtManager, token)) revert UnsupportedToken();
        uint256 amount = debtManager.convertUsdToCollateralToken(token, amountInUsd);
        if (amount == 0) revert AmountZero();

        $$.transactionCleared[txId] = true;
        $$.spendingLimit.spend(amountInUsd);

        _retrievePendingCashback($, safe, spender);
        _spend($, debtManager, safe, spender, token, amountInUsd, amount);
    }

    /**
     * @notice Attempts to retrieve pending cashback for a safe and/or spender
     * @dev Calls the cashback dispatcher to clear pending cashback and updates storage if successful
     * @param $ Storage reference to the CashModuleStorage
     * @param safe Address of the EtherFi Safe
     * @param spender Address of the spender who may have pending cashback
     */
    function _retrievePendingCashback(CashModuleStorage storage $, address safe, address spender) internal {
        ICashEventEmitter eventEmitter = $.cashEventEmitter;
        address cashbackToken;
        uint256 cashbackAmount;
        bool paid;

        if ($.pendingCashbackInUsd[safe] != 0) {
            (cashbackToken, cashbackAmount, paid) = $.cashbackDispatcher.clearPendingCashback(safe);
            if (paid) {
                eventEmitter.emitPendingCashbackClearedEvent(safe, safe, cashbackToken, cashbackAmount, $.pendingCashbackInUsd[safe]);
                delete $.pendingCashbackInUsd[safe];
            }
        }

        if ($.pendingCashbackInUsd[spender] != 0) {
            (cashbackToken, cashbackAmount, paid) = $.cashbackDispatcher.clearPendingCashback(spender);
            if (paid) {
                eventEmitter.emitPendingCashbackClearedEvent(safe, spender, cashbackToken, cashbackAmount, $.pendingCashbackInUsd[spender]);
                delete $.pendingCashbackInUsd[spender];
            }
        }
    }

    /**
     * @dev Internal function to execute the spending transaction
     * @param $ Storage reference to the CashModuleStorage
     * @param debtManager Reference to the debt manager contract
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to spend
     * @param amount Amount of tokens to spend
     * @custom:throws BorrowingsExceedMaxBorrowAfterSpending if spending would exceed borrowing limits
     */
    function _spend(CashModuleStorage storage $, IDebtManager debtManager, address safe, address spender, address token, uint256 amountInUsd, uint256 amount) internal {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        if ($$.mode == Mode.Credit) {
            to[0] = address(debtManager);
            data[0] = abi.encodeWithSelector(IDebtManager.borrow.selector, token, amount);
            values[0] = 0;

            try IEtherFiSafe(safe).execTransactionFromModule(to, values, data) { }
            catch {
                _cancelOldWithdrawal(safe);
                IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
            }
        } else {
            _updateWithdrawalRequestIfNecessary(safe, token, amount);
            (IDebtManager.TokenData[] memory collateralTokenAmounts,) = _getCollateralBalanceWithTokenSubtracted(debtManager, safe, token, amount, $$.mode);
            (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);

            if (totalBorrowings > totalMaxBorrow && $$.pendingWithdrawalRequest.tokens.length != 0) {
                _cancelOldWithdrawal(safe);
                (collateralTokenAmounts,) = _getCollateralBalanceWithTokenSubtracted(debtManager, safe, token, amount, $$.mode);
                (totalMaxBorrow, totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
            }
            if (totalBorrowings > totalMaxBorrow) revert BorrowingsExceedMaxBorrowAfterSpending();

            to[0] = token;
            data[0] = abi.encodeWithSelector(IERC20.transfer.selector, _getCashModuleStorage().settlementDispatcher, amount);
            values[0] = 0;
            IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        }

        _cashback($, safe, spender, amountInUsd);
        $.cashEventEmitter.emitSpend(safe, token, amount, amountInUsd, $$.mode);
    }

    /**
     * @notice Processes cashback for a spending transaction
     * @dev Calculates and distributes cashback between safe and spender based on settings
     * @param $ Storage reference to the CashModuleStorage
     * @param safe Address of the EtherFi Safe
     * @param spender Address of the spender who triggered the cashback
     * @param amountInUsd Amount spent in USD that is eligible for cashback
     */
    function _cashback(CashModuleStorage storage $, address safe, address spender, uint256 amountInUsd) internal {
        (uint256 cashbackPercentage, uint256 cashbackSplitToSafePercentage) = getSafeCashbackPercentageAndSplit(safe);

        (address cashbackToken, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) = $.cashbackDispatcher.cashback(safe, spender, amountInUsd, cashbackPercentage, cashbackSplitToSafePercentage);

        if (!paid) {
            $.pendingCashbackInUsd[safe] += cashbackInUsdToSafe;
            $.pendingCashbackInUsd[spender] += cashbackInUsdToSpender;
        }

        $.safeCashConfig[safe].totalCashbackEarnedInUsd += cashbackInUsdToSafe + cashbackInUsdToSpender;

        $.cashEventEmitter.emitCashbackEvent(safe, spender, amountInUsd, cashbackToken, cashbackAmountToSafe, cashbackInUsdToSafe, cashbackAmountToSpender, cashbackInUsdToSpender, paid);
    }

    /**
     * @notice Repays borrowed tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws OnlyBorrowToken if token is not a valid borrow token
     */
    function repay(address safe, address token, uint256 amountInUsd) public onlyEtherFiWallet onlyEtherFiSafe(safe) {
        IDebtManager debtManager = getDebtManager();
        if (!_isBorrowToken(debtManager, token)) revert OnlyBorrowToken();
        _repay(safe, debtManager, token, amountInUsd);
    }

    /**
     * @dev Internal function to execute the repayment transaction
     * @param safe Address of the EtherFi Safe
     * @param debtManager Reference to the debt manager contract
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws AmountZero if the converted amount is zero
     */
    function _repay(address safe, IDebtManager debtManager, address token, uint256 amountInUsd) internal {
        uint256 amount = IDebtManager(debtManager).convertUsdToCollateralToken(token, amountInUsd);
        if (amount == 0) revert AmountZero();
        _updateWithdrawalRequestIfNecessary(safe, token, amount);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = token;
        to[1] = address(debtManager);

        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(debtManager), amount);
        data[1] = abi.encodeWithSelector(IDebtManager.repay.selector, safe, token, amount);

        values[0] = 0;
        values[1] = 0;

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        _getCashModuleStorage().cashEventEmitter.emitRepayDebtManager(safe, token, amount, amountInUsd);
    }

    /**
     * @notice Gets the pending withdrawal amount for a token
     * @dev Only callable for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to check
     * @return Amount of tokens pending withdrawal
     * @custom:throws If the address is not a valid EtherFi Safe
     */
    function getPendingWithdrawalAmount(address safe, address token) public view onlyEtherFiSafe(safe) returns (uint256) {
        WithdrawalRequest memory withdrawalRequest = _getCashModuleStorage().safeCashConfig[safe].pendingWithdrawalRequest;
        uint256 len = withdrawalRequest.tokens.length;
        uint256 tokenIndex = len;
        for (uint256 i = 0; i < len;) {
            if (withdrawalRequest.tokens[i] == token) {
                tokenIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        return tokenIndex != len ? withdrawalRequest.amounts[tokenIndex] : 0;
    }

    /**
     * @dev Calculates collateral balance with a token amount subtracted
     * @param debtManager Reference to the debt manager contract
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to subtract
     * @param amount Amount to subtract
     * @param __mode Operating mode (Credit or Debit)
     * @return tokenAmounts Array of token data with updated balances
     * @return error Error message if calculation fails
     */
    function _getCollateralBalanceWithTokenSubtracted(IDebtManager debtManager, address safe, address token, uint256 amount, Mode __mode) internal view returns (IDebtManager.TokenData[] memory, string memory error) {
        address[] memory collateralTokens = debtManager.getCollateralTokens();
        uint256 len = collateralTokens.length;
        IDebtManager.TokenData[] memory tokenAmounts = new IDebtManager.TokenData[](collateralTokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < len;) {
            uint256 balance = IERC20(collateralTokens[i]).balanceOf(safe);
            uint256 pendingWithdrawalAmount = getPendingWithdrawalAmount(safe, collateralTokens[i]);
            if (balance != 0) {
                balance = balance - pendingWithdrawalAmount;
                if (__mode == Mode.Debit && token == collateralTokens[i]) {
                    if (balance == 0 || balance < amount) return (new IDebtManager.TokenData[](0), "Insufficient effective balance after withdrawal to spend with debit mode");
                    balance = balance - amount;
                }
                tokenAmounts[m] = IDebtManager.TokenData({ token: collateralTokens[i], amount: balance });
                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(tokenAmounts, m)
        }

        return (tokenAmounts, "");
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
     * @notice Checks if a safe has sufficient balance for all tokens and amounts
     * @dev Called before creating a withdrawal request to prevent invalid requests
     * @param safe Address of the EtherFi Safe
     * @param tokens Array of token addresses to check
     * @param amounts Array of token amounts to check
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws InsufficientBalance if any token has insufficient balance
     */
    function _checkBalance(address safe, address[] calldata tokens, uint256[] calldata amounts) internal view {
        uint256 len = tokens.length;
        if (len != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len;) {
            if (IERC20(tokens[i]).balanceOf(safe) < amounts[i]) revert InsufficientBalance();

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal implementation of withdrawal request logic
     * @dev Creates a pending withdrawal request and emits events
     * @param safe Address of the EtherFi Safe
     * @param tokens Array of token addresses to withdraw
     * @param amounts Array of token amounts to withdraw
     * @param recipient Address to receive the withdrawn tokens
     * @custom:throws RecipientCannotBeAddressZero if recipient is the zero address
     * @custom:throws OnlyWhitelistedWithdrawRecipients if recipient is not whitelisted
     */
    function _requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();

        if (recipient == address(0)) revert RecipientCannotBeAddressZero();
        if (!$.safeCashConfig[safe].withdrawRecipients.contains(recipient)) revert OnlyWhitelistedWithdrawRecipients();

        if (tokens.length > 1) tokens.checkDuplicates();

        _cancelOldWithdrawal(safe);

        uint96 finalTime = uint96(block.timestamp) + $.withdrawalDelay;

        _checkBalance(safe, tokens, amounts);

        $.safeCashConfig[safe].pendingWithdrawalRequest = WithdrawalRequest({ tokens: tokens, amounts: amounts, recipient: recipient, finalizeTime: finalTime });
        $.cashEventEmitter.emitWithdrawalRequested(safe, tokens, amounts, recipient, finalTime);

        getDebtManager().ensureHealth(safe);

        if ($.withdrawalDelay == 0) processWithdrawal(safe);
    }
}
