// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ICashEventEmitter } from "../../interfaces/ICashEventEmitter.sol";
import { Mode, BinSponsor, SafeCashConfig, SafeData, SafeTiers, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
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
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashModule
 * @notice Cash features for EtherFi Safe accounts
 * @author ether.fi
 */
contract CashModuleCore is CashModuleStorageContract {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using SpendingLimitLib for SpendingLimit;
    using MessageHashUtils for bytes32;
    using ArrayDeDupLib for address[];

    constructor(address _etherFiDataProvider) CashModuleStorageContract(_etherFiDataProvider) { 
        _disableInitializers();
    }

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
     */
    function initialize(address _roleRegistry, address _debtManager, address _settlementDispatcherReap, address _settlementDispatcherRain, address _cashbackDispatcher, address _cashEventEmitter, address _cashModuleSetters) external initializer {
        __UpgradeableProxy_init(_roleRegistry);

        CashModuleStorage storage $ = _getCashModuleStorage();

        $.debtManager = IDebtManager(_debtManager);

        if (_settlementDispatcherReap == address(0) || _settlementDispatcherRain == address(0) || _cashbackDispatcher == address(0) || _cashEventEmitter == address(0)) revert InvalidInput();
        $.settlementDispatcherReap = _settlementDispatcherReap;
        $.settlementDispatcherRain = _settlementDispatcherRain;
        $.cashbackDispatcher = ICashbackDispatcher(_cashbackDispatcher);
        $.cashEventEmitter = ICashEventEmitter(_cashEventEmitter);

        $.withdrawalDelay = 1; // 1 sec
        $.spendLimitDelay = 3600; // 1 hour
        $.modeDelay = 1; // 1 sec

        $.cashModuleSetters = _cashModuleSetters;

        $.tierCashbackPercentage[SafeTiers.Pepe] = 2_00; // 2%
        $.tierCashbackPercentage[SafeTiers.Wojak] = 3_00; // 3%
        $.tierCashbackPercentage[SafeTiers.Chad] = 4_00; // 4%
        $.tierCashbackPercentage[SafeTiers.Whale] = 4_00; // 4%
        $.tierCashbackPercentage[SafeTiers.Business] = 2_00; // 2%
        $.referrerCashbackPercentageInBps = 1_00; // 1%
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
        $.cashbackSplitToSafePercentage = 0; // 0% goes to safe, 100% goes to spender by default
    }

    /**
     * @notice Sets the new CashModuleSetters implementation address
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param newCashModuleSetters Address of the new CashModuleSetters implementation
     * @custom:throws OnlyCashModuleController if caller doesn't have the controller role
     * @custom:throws InvalidInput if newCashModuleSetters = address(0)
     */
    function setCashModuleSettersAddress(address newCashModuleSetters) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();
        if (newCashModuleSetters == address(0)) revert InvalidInput();
        _getCashModuleStorage().cashModuleSetters = newCashModuleSetters;
    }

    function getCashEventEmitter() external view returns (address) {
        return address(_getCashModuleStorage().cashEventEmitter);
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
     * @notice Fetches the safe tier
     * @param safe Address of the safe
     * @return SafeTiers Tier of the safe
     */
    function getSafeTier(address safe) external view onlyEtherFiSafe(safe) returns (SafeTiers) {
        return _getCashModuleStorage().safeCashConfig[safe].safeTier;
    }

    /**
     * @notice Fetches Cashback Percentage for a safe tier
     * @return uint256 Cashback Percentage in bps
     */
    function getTierCashbackPercentage(SafeTiers tier) external view returns (uint256) {
        return _getCashModuleStorage().tierCashbackPercentage[tier];
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
     * @dev The settlement dispatcher receives the funds that are spent
     * @param binSponsor Bin sponsor for which the settlement dispatcher needs to be returned
     * @return settlementDispatcher The address of the settlement dispatcher
     * @custom:throws SettlementDispatcherNotSetForBinSponsor If the address of the settlement dispatcher is address(0) for bin sponsor
     */
    function getSettlementDispatcher(BinSponsor binSponsor) public view returns (address settlementDispatcher) {
        if (binSponsor == BinSponsor.Rain) settlementDispatcher = _getCashModuleStorage().settlementDispatcherRain;
        else settlementDispatcher = _getCashModuleStorage().settlementDispatcherReap;

        if (settlementDispatcher == address(0)) revert SettlementDispatcherNotSetForBinSponsor();
    }

    /**
     * @notice Gets the referrer cashback percentage in bps
     * @return uint64 referrer cashback percentage in bps
     */
    function getReferrerCashbackPercentage() external view returns (uint64) {
        return _getCashModuleStorage().referrerCashbackPercentageInBps;
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
                to[counter] = tokensToSend[i].token;
                data[counter] = abi.encodeWithSelector(IERC20.transfer.selector, liquidator, tokensToSend[i].amount);
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
     * @notice Processes a pending withdrawal request after the delay period
     * @dev Executes the token transfers and clears the request
     * @param safe Address of the EtherFi Safe
     * @custom:throws CannotWithdrawYet if the withdrawal delay period hasn't passed
     */
    function processWithdrawal(address safe) public onlyEtherFiSafe(safe) {
        _processWithdrawal(safe);
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

    function getDebtManager() public view returns (IDebtManager) {
        return _getDebtManager();
    }

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
    function spend(address safe,  address spender, address referrer,  bytes32 txId, BinSponsor binSponsor,  address[] calldata tokens,  uint256[] calldata amountsInUsd,  bool shouldReceiveCashback) external whenNotPaused onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();

        uint256 totalSpendingInUsd = _validateSpend($.safeCashConfig[safe], safe, spender, txId, tokens, amountsInUsd);        
                
        // Process all token transfers based on mode
        if ($.safeCashConfig[safe].mode == Mode.Credit)  _spendCredit($, safe, txId, spender, referrer, binSponsor, tokens, amountsInUsd, totalSpendingInUsd, shouldReceiveCashback);
        else _spendDebit($, safe, txId, spender, referrer, binSponsor, tokens, amountsInUsd, totalSpendingInUsd, shouldReceiveCashback);
    }

    function _validateSpend(SafeCashConfig storage $$, address safe,  address spender,  bytes32 txId, address[] calldata tokens,  uint256[] calldata amountsInUsd) internal returns(uint256) {
        // Input validation
        if (tokens.length == 0) revert InvalidInput();
        if (tokens.length != amountsInUsd.length) revert ArrayLengthMismatch();
        if (spender == safe) revert InvalidInput();

        // Set current mode and check transaction status
        _setCurrentMode($$);
        if ($$.transactionCleared[txId]) revert TransactionAlreadyCleared();
        
        // In Credit mode, only one token is allowed
        if ($$.mode == Mode.Credit && tokens.length > 1) revert OnlyOneTokenAllowedInCreditMode();

        // Calculate total spending amount in USD
        uint256 totalSpendingInUsd = 0;
        for (uint256 i = 0; i < amountsInUsd.length; i++) {
            totalSpendingInUsd += amountsInUsd[i];
        }

        if (totalSpendingInUsd == 0) revert AmountZero();
        
        // Update spending limit
        $$.transactionCleared[txId] = true;
        $$.spendingLimit.spend(totalSpendingInUsd);

        // Retrieve any pending cashback for safe and spender
        _retrievePendingCashback(spender);
        _retrievePendingCashback(safe);

        return totalSpendingInUsd;
    }

    /**
     * @dev Internal function to execute credit mode spending transaction (single token)
     * @param $ Storage reference to the CashModuleStorage
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param spender Address of the spender
     * @param tokens Addresses of the tokens to spend
     * @param amountsInUsd Amounts to spend in USD
     * @param shouldReceiveCashback Flag indicating if cashback should be processed
     */
    function _spendCredit(CashModuleStorage storage $, address safe, bytes32 txId, address spender, address referrer, BinSponsor binSponsor, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd, bool shouldReceiveCashback) internal {
        // Credit mode validation
        if (!_isBorrowToken($.debtManager, tokens[0])) revert UnsupportedToken();
        uint256 amount = $.debtManager.convertUsdToCollateralToken(tokens[0], amountsInUsd[0]);
        if (amount == 0) revert AmountZero();
        
        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        to[0] = address($.debtManager);
        data[0] = abi.encodeWithSelector(IDebtManager.borrow.selector, binSponsor, tokens[0], amount);
        values[0] = 0;

        try IEtherFiSafe(safe).execTransactionFromModule(to, values, data) { }
        catch {
            _cancelOldWithdrawal(safe);
            IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        }

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, tokens, amounts, amountsInUsd, totalSpendingInUsd, Mode.Credit);
        if (shouldReceiveCashback) {
            _cashback($, safe, spender, amountsInUsd[0]);
            if (referrer != address(0)) _referrerCashback($, safe, referrer, totalSpendingInUsd);
        }
    }

    /**
     * @dev Internal function to execute debit mode spending transactions (multiple tokens)
     * @param $ Storage reference to the CashModuleStorage
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param spender Address of the spender
     * @param tokens Array of addresses of the tokens to spend
     * @param amountsInUsd Array of amounts to spend in USD
     * @param shouldReceiveCashback Flag indicating if cashback should be processed
     */
    function _spendDebit(CashModuleStorage storage $, address safe, bytes32 txId, address spender, address referrer, BinSponsor binSponsor, address[] calldata tokens, uint256[] calldata amountsInUsd, uint256 totalSpendingInUsd, bool shouldReceiveCashback) internal {
        uint256[] memory amounts = new uint256[](tokens.length);
        
        // Convert USD amounts to token amounts and validate
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!_isBorrowToken($.debtManager, tokens[i])) revert UnsupportedToken();
            amounts[i] = $.debtManager.convertUsdToCollateralToken(tokens[i], amountsInUsd[i]);
            if (IERC20(tokens[i]).balanceOf(safe) < amounts[i]) revert InsufficientBalance();
            
            _updateWithdrawalRequestIfNecessary(safe, tokens[i], amounts[i]);
        }

        _spendDebit(safe, binSponsor, tokens, amounts);

        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, tokens, amounts, amountsInUsd, totalSpendingInUsd, Mode.Debit);
        $.debtManager.ensureHealth(safe);
        if (shouldReceiveCashback) {
            _cashback($, safe, spender, totalSpendingInUsd);
            if (referrer != address(0)) _referrerCashback($, safe, referrer, totalSpendingInUsd);
        } 
    }

    function _spendDebit(address safe, BinSponsor binSponsor,  address[] calldata tokens, uint256[] memory amounts) internal {
        // Execute transfers to settlement dispatcher for all tokens
        address[] memory to = new address[](tokens.length);
        bytes[] memory data = new bytes[](tokens.length);
        uint256[] memory values = new uint256[](tokens.length);
        
        address settlementDispatcher = getSettlementDispatcher(binSponsor);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            to[i] = tokens[i];
            data[i] = abi.encodeWithSelector(IERC20.transfer.selector, settlementDispatcher, amounts[i]);
            values[i] = 0;
        }
        try IEtherFiSafe(safe).execTransactionFromModule(to, values, data) {}
        catch {
            _cancelOldWithdrawal(safe);
            IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        }
    }
    
    /**
     * @notice Clears pending cashback for users
     * @param users Addresses of users to clear the pending cashback for
     */
    function clearPendingCashback(address[] calldata users) external whenNotPaused {
        uint256 len = users.length;
        if (len == 0) revert InvalidInput();
        
        for (uint256 i = 0; i < len; ) {
            if (users[i] == address(0)) revert InvalidInput();
            
            _retrievePendingCashback(users[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Attempts to retrieve pending cashback for a user
     * @dev Calls the cashback dispatcher to clear pending cashback and updates storage if successful
     * @param user Address of the user who may have pending cashback
     */
    function _retrievePendingCashback(address user) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();

        if ($.pendingCashbackInUsd[user] != 0) {
            (address cashbackToken, uint256 cashbackAmount, bool paid) = $.cashbackDispatcher.clearPendingCashback(user);
            if (paid) {
                $.cashEventEmitter.emitPendingCashbackClearedEvent(user, cashbackToken, cashbackAmount, $.pendingCashbackInUsd[user]);
                delete $.pendingCashbackInUsd[user];
            }
        }
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
     * @notice Processes referrer cashback for a spending transaction
     * @dev Calculates and distributes cashback to the referrer
     * @param $ Storage reference to the CashModuleStorage
     * @param safe Address of the EtherFi Safe
     * @param referrer Address of the referrer 
     * @param amountInUsd Amount spent in USD that is eligible for cashback
     */
    function _referrerCashback(CashModuleStorage storage $, address safe, address referrer, uint256 amountInUsd) internal {
        if ($.referrerCashbackPercentageInBps > 0) {
            (address cashbackToken, , , uint256 cashbackAmountToReferrer, uint256 cashbackInUsdToReferrer, bool paid) = $.cashbackDispatcher.cashback(safe, referrer, amountInUsd, $.referrerCashbackPercentageInBps, 0);
            if (!paid) $.pendingCashbackInUsd[referrer] += cashbackInUsdToReferrer;
            $.cashEventEmitter.emitReferrerCashbackEvent(safe, referrer, amountInUsd, cashbackToken, cashbackAmountToReferrer, cashbackInUsdToReferrer, paid);
        }
    }

    /**
     * @notice Repays borrowed tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws OnlyBorrowToken if token is not a valid borrow token
     */
    function repay(address safe, address token, uint256 amountInUsd) public whenNotPaused onlyEtherFiWallet onlyEtherFiSafe(safe) {
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

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = token;
        to[1] = address(debtManager);
        to[2] = token;

        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(debtManager), amount);
        data[1] = abi.encodeWithSelector(IDebtManager.repay.selector, safe, token, amount);
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, address(debtManager), 0);

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
     * @notice Fetches the address Cash Module Setters contract
     * @return address Cash Module Setters
     */
    function getCashModuleSetters() public view returns (address) {
        return _getCashModuleStorage().cashModuleSetters;
    }

    /**
     * @dev Falldown to the admin implementation
     * @notice This is a catch all for all functions not declared in core
     */
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address settersImpl = getCashModuleSetters();
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), settersImpl, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
