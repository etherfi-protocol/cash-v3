// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ICashEventEmitter } from "../../interfaces/ICashEventEmitter.sol";
import { Mode, BinSponsor, SafeCashConfig, SafeData, SafeTiers, WithdrawalRequest, TokenDataInUsd, Cashback, CashbackTokens } from "../../interfaces/ICashModule.sol";
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
import { IPendingHoldsModule } from "../../interfaces/IPendingHoldsModule.sol";
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

    /**
     * @notice Returns the address of CashEventEmitter contract
     * @return CashEventEmitter contract address
     */
    function getCashEventEmitter() external view returns (address) {
        return address(_getCashModuleStorage().cashEventEmitter);
    }

    /**
     * @notice Returns all the assets whitelisted for withdrawals
     * @return Array of whitelisted withdraw assets
     */    
    function getWhitelistedWithdrawAssets() external view returns (address[] memory) {
        return _getCashModuleStorage().whitelistedWithdrawAssets.values();
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
     * @param tokens Addresses of tokens for cashback
     * @return data Pending cashback data for tokens in USD
     * @return totalCashbackInUsd Total pending cashback amount in USD
     */
    function getPendingCashback(address account, address[] memory tokens) external view returns (TokenDataInUsd[] memory data, uint256 totalCashbackInUsd) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        
        uint256 len = tokens.length;
        if (len > 1) tokens.checkDuplicates();
        data = new TokenDataInUsd[](len);
        uint256 m = 0;

        for (uint256 i = 0; i < len; ) {
            uint256 pendingCashbackInUsd = $.pendingCashbackForTokenInUsd[account][tokens[i]];
            if (pendingCashbackInUsd > 0) {
                data[m] = TokenDataInUsd({
                    token: tokens[i],
                    amountInUsd: pendingCashbackInUsd
                });

                totalCashbackInUsd += pendingCashbackInUsd;

                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(data, m)
        }
    }
 
    /**
     * @notice Gets the pending cashback amount for an account in USD for a specific token
     * @dev Returns the amount of cashback waiting to be claimed
     * @param account Address of the account (safe or spender)
     * @param token Address of tokens for cashback
     * @return Pending cashback amount in USD for the token
     */
    function getPendingCashbackForToken(address account, address token) public view returns (uint256) {
        return _getCashModuleStorage().pendingCashbackForTokenInUsd[account][token];
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
        else if (binSponsor == BinSponsor.PIX) settlementDispatcher = _getCashModuleStorage().settlementDispatcherPix;
        else if (binSponsor == BinSponsor.CardOrder) settlementDispatcher = _getCashModuleStorage().settlementDispatcherCardOrder;
        else settlementDispatcher = _getCashModuleStorage().settlementDispatcherReap;

        if (settlementDispatcher == address(0)) revert SettlementDispatcherNotSetForBinSponsor();
    }

    /**
     * @notice Gets the current operating mode of a safe
     * @dev Considers pending mode changes that have passed their delay
     * @param safe Address of the EtherFi Safe
     * @return The current operating mode (Debit or Credit)
     */
    function getMode(address safe) external view returns (Mode) {
        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[safe];

        if ($.incomingModeStartTime != 0 && block.timestamp > $.incomingModeStartTime) return $.incomingMode;
        return $.mode;
    }

    /**
     * @notice Gets the timestamp when a pending mode change will take effect
     * @dev Returns 0 if no pending change or if the safe uses debit mode
     * @param safe Address of the EtherFi Safe
     * @return Timestamp when incoming mode will take effect, or 0 if not applicable
     */
    function incomingModeStartTime(address safe) external view returns (uint256) {
        return _getCashModuleStorage().safeCashConfig[safe].incomingModeStartTime;
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
    function processWithdrawal(address safe) public onlyEtherFiSafe(safe) nonReentrant {
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
        SafeData memory data = SafeData({ spendingLimit: $.spendingLimit, pendingWithdrawalRequest: $.pendingWithdrawalRequest, mode: $.mode, incomingModeStartTime: $.incomingModeStartTime, totalCashbackEarnedInUsd: $.totalCashbackEarnedInUsd, incomingMode: $.incomingMode });

        return data;
    }

    /**
     * @notice Returns the list of modules that can request withdrawals
     * @return Array of module addresses that can request withdrawals
     */
    function getWhitelistedModulesCanRequestWithdraw() external view returns (address[] memory) {
        return _getCashModuleStorage().whitelistedModulesCanRequestWithdraw.values();
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
     * @notice Returns an instance of the Debt Manager contract
     * @return Debt Manager instance
     */
    function getDebtManager() public view returns (IDebtManager) {
        return _getDebtManager();
    }

    /**
     * @notice Processes a spending transaction with multiple tokens
     * @dev Unified settlement path — handles both normal (hold exists) and recovery (no hold) cases.
     *
     *      Hold-sync step (before token transfer):
     *        - Hold exists, non-forced: update hold to settlement amount; charge/release limit delta.
     *        - Hold exists, forced:     update hold to settlement amount; no limit adjustment.
     *        - No hold:                 create forced hold; bypass limit ("Settlement is KING").
     *        - No PHM:                  charge spendingLimit.spend() directly (legacy path).
     *
     *      Spend step:
     *        - Credit mode: borrow full settlement amount; all-or-nothing.
     *        - Debit mode:  transfer min(required, available) per token; partial spend supported.
     *
     *      Finalize step (after token transfer):
     *        - Fully spent (remaining == 0): removeHold().
     *        - Partially spent (remaining > 0): settlementSetRemainingHold(remaining) — hold
     *          tracks outstanding debt; a separate special function handles clearance.
     *
     *      Emits Spend with the ACTUALLY spent amount, not the settlement amount if partial.
     *
     *      Only callable by EtherFi wallet for valid EtherFi Safe addresses.
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param binSponsor Bin sponsor used for spending
     * @param tokens Array of addresses of the tokens to spend
     * @param amountsInUsd Array of amounts to spend in USD (must match tokens array length)
     * @param cashbacks Struct of Cashback to be given
     * @custom:throws TransactionAlreadyCleared if the transaction was already processed
     * @custom:throws UnsupportedToken if any token is not supported
     * @custom:throws AmountZero if total amounts are zero
     * @custom:throws ArrayLengthMismatch if token and amount arrays have different lengths
     * @custom:throws OnlyOneTokenAllowedInCreditMode if multiple tokens are used in credit mode
     */
    function spend(address safe, bytes32 txId, BinSponsor binSponsor, address[] calldata tokens, uint256[] calldata amountsInUsd, Cashback[] calldata cashbacks) external whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();

        uint256 totalSpendingInUsd = _validateSpend($.safeCashConfig[safe], txId, tokens, amountsInUsd);

        // Sync hold to settlement amount (or create forced hold). Handle limit delta in Core to
        // avoid a PHM→Core callback re-entering the nonReentrant spend() context.
        _phmSettleHold($, safe, binSponsor, txId, totalSpendingInUsd);

        uint256 actualSpendInUsd;
        if ($.safeCashConfig[safe].mode == Mode.Credit) {
            _spendCredit($, safe, txId, binSponsor, tokens, amountsInUsd, totalSpendingInUsd);
            actualSpendInUsd = totalSpendingInUsd;
        } else {
            actualSpendInUsd = _spendDebitPartial($, safe, txId, binSponsor, tokens, amountsInUsd);
            // When PHM is unset, partial settlement has nowhere to record the remainder —
            // transactionCleared[txId] is already set and _phmFinalize is a no-op, so any
            // untransferred amount would become silent debt. Require full settlement here
            // to preserve strict debit semantics for legacy / pre-PHM deployments.
            if ($.pendingHoldsModule == address(0) && actualSpendInUsd != totalSpendingInUsd) {
                revert InsufficientBalance();
            }
        }

        _phmFinalize($, safe, binSponsor, txId, totalSpendingInUsd, actualSpendInUsd);
        _cashback($, safe, actualSpendInUsd, cashbacks);
    }

    function _validateSpend(SafeCashConfig storage $$, bytes32 txId, address[] calldata tokens, uint256[] calldata amountsInUsd) internal returns(uint256) {
        // Input validation
        if (tokens.length == 0) revert InvalidInput();
        if (tokens.length != amountsInUsd.length) revert ArrayLengthMismatch();

        if (tokens.length > 1) tokens.checkDuplicates();

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

        $$.transactionCleared[txId] = true;
        // NOTE: spendingLimit.spend() is NOT called here. Callers are responsible:
        //   - spend():      skips if hold was non-forced (limit already consumed at addHold time)
        //   - forceSpend(): skips if hold was non-forced; always charges otherwise
        //   - No-PHM path: always calls spendingLimit.spend() at settlement

        return totalSpendingInUsd;
    }

    /**
     * @dev Syncs/creates a hold via PHM and handles spending-limit accounting for spend().
     *      Extracted to its own stack frame to avoid stack-too-deep in callers.
     *
     *      Limit accounting rules after settlementSyncHold() returns:
     *        - No hold existed (Settlement is KING): bypass limit — no charge.
     *        - Non-forced hold, settlement > old:   charge delta to limit.
     *        - Non-forced hold, settlement < old:   release delta from limit.
     *        - Non-forced hold, settlement == old:  no-op.
     *        - Forced hold (forceAddHold path):     charge full settlement to limit now,
     *                                               since limit was bypassed at forceAddHold.
     *        - No PHM:                              charge spendingLimit.spend(amount) directly.
     *
     *      Limit adjustments are performed in Core — NOT via a PHM→Core callback — to avoid
     *      re-entering the nonReentrant spend() context through CashModuleSetters.
     */
    function _phmSettleHold(CashModuleStorage storage $, address safe, BinSponsor binSponsor, bytes32 txId, uint256 amount) private {
        address phm = $.pendingHoldsModule;
        if (phm == address(0)) {
            $.safeCashConfig[safe].spendingLimit.spend(amount);
            return;
        }
        (bool existed, bool wasForced, uint256 oldAmount) =
            IPendingHoldsModule(phm).settlementSyncHold(safe, binSponsor, txId, amount);
        if (!existed) {
            // Settlement is KING — no prior hold, bypass limit entirely.
            return;
        }
        if (!wasForced) {
            // Non-forced hold: limit was pre-charged at addHold for oldAmount; adjust for delta.
            if (amount > oldAmount) {
                $.safeCashConfig[safe].spendingLimit.spend(amount - oldAmount);
            } else if (amount < oldAmount) {
                $.safeCashConfig[safe].spendingLimit.release(oldAmount - amount);
            }
        } else {
            // Forced hold (forceAddHold path): limit was bypassed at creation — charge now.
            $.safeCashConfig[safe].spendingLimit.spend(amount);
        }
    }

    /**
     * @dev Finalizes the hold state after spend() executes the token transfer.
     *      - remaining == 0: removeHold() — fully settled.
     *      - remaining  > 0: settlementSetRemainingHold(remaining) — partial settlement; the
     *        remaining hold tracks outstanding debt for the special-function clearance path.
     */
    function _phmFinalize(CashModuleStorage storage $, address safe, BinSponsor binSponsor, bytes32 txId, uint256 total, uint256 actual) private {
        address phm = $.pendingHoldsModule;
        if (phm == address(0)) return;
        uint256 remaining = total - actual;
        if (remaining == 0) {
            IPendingHoldsModule(phm).removeHold(safe, binSponsor, txId);
        } else {
            IPendingHoldsModule(phm).settlementSetRemainingHold(safe, binSponsor, txId, remaining);
        }
    }

    /**
     * @dev Internal function to execute credit mode spending transaction (single token)
     * @param $ Storage reference to the CashModuleStorage
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param tokens Addresses of the tokens to spend
     * @param amountsInUsd Amounts to spend in USD
     */
    function _spendCredit(CashModuleStorage storage $, address safe, bytes32 txId, BinSponsor binSponsor, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd) internal {
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
    }

    /**
     * @dev Executes a debit-mode spend, capping each token at the safe's available balance.
     *      Returns the total USD actually transferred (may be less than the requested total if
     *      any token balance is insufficient — partial settlement).
     *
     *      For each token:
     *        - Converts amountsInUsd[i] → required token amount via debtManager price oracle.
     *        - If balance >= required: transfer required; actualUsd[i] = amountsInUsd[i].
     *        - If balance  < required: transfer available; actualUsd[i] proportionally scaled.
     *
     *      Emits Spend with the actually transferred amounts and actualSpendInUsd total.
     *      Caller (_phmFinalize) updates or removes the hold for any remaining USD.
     */
    function _spendDebitPartial(CashModuleStorage storage $, address safe, bytes32 txId, BinSponsor binSponsor, address[] calldata tokens, uint256[] calldata amountsInUsd) internal returns (uint256 actualSpendInUsd) {
        uint256[] memory amounts = new uint256[](tokens.length);
        uint256[] memory actualUsd = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (!_isBorrowToken($.debtManager, tokens[i])) revert UnsupportedToken();
            // Use amounts[i] as "required" first, then overwrite if partial.
            amounts[i] = $.debtManager.convertUsdToCollateralToken(tokens[i], amountsInUsd[i]);
            uint256 available = IERC20(tokens[i]).balanceOf(safe);
            if (available < amounts[i]) {
                // Partial: scale USD proportionally; cap token transfer at available.
                actualUsd[i] = amounts[i] > 0 ? amountsInUsd[i] * available / amounts[i] : 0;
                amounts[i] = available;
            } else {
                actualUsd[i] = amountsInUsd[i];
            }
            actualSpendInUsd += actualUsd[i];
            _cancelWithdrawalRequestIfNecessary(safe, tokens[i], amounts[i]);
        }

        _spendDebit(safe, binSponsor, tokens, amounts);

        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, tokens, amounts, actualUsd, actualSpendInUsd, Mode.Debit);

        // Ensuring the account is healthy; retry once after canceling any pending withdrawal.
        try $.debtManager.ensureHealth(safe) {}
        catch {
            _cancelOldWithdrawal(safe);
            $.debtManager.ensureHealth(safe);
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
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }
    
    /**
     * @notice Clears pending cashback for users
     * @param users Addresses of users to clear the pending cashback for
     * @param tokens Addresses of cashback tokens
     */
    function clearPendingCashback(address[] calldata users, address[] calldata tokens) external nonReentrant whenNotPaused {
        uint256 len = users.length;
        if (len == 0) revert InvalidInput();
        if (tokens.length > 1) tokens.checkDuplicates();
        if (len > 1) users.checkDuplicates();
        
        for (uint256 i = 0; i < len; ) {
            if (users[i] == address(0)) revert InvalidInput();
            
            for(uint256 j = 0; j < tokens.length; ) {
                if (tokens[j] == address(0)) revert InvalidInput();
                
                _retrievePendingCashback(users[i], tokens[j]);
                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Attempts to retrieve pending cashback for a user
     * @dev Calls the cashback dispatcher to clear pending cashback and updates storage if successful
     * @param user Address of the user who may have pending cashback
     * @param token Address of the cashback token
     */
    function _retrievePendingCashback(address user, address token) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();

        uint256 amountInUsd = getPendingCashbackForToken(user, token);

        if (amountInUsd > 0) {
            try $.cashbackDispatcher.clearPendingCashback(user, token, amountInUsd) returns (uint256 cashbackAmountInToken, bool paid) {
                if (paid) {
                    $.cashEventEmitter.emitPendingCashbackClearedEvent(user, token, cashbackAmountInToken, amountInUsd);
                    delete $.pendingCashbackForTokenInUsd[user][token];
                }
            } catch {}
        }
    }

    /**
     * @notice Processes cashback for a spending transaction
     * @dev Calculates and distributes cashback 
     * @param $ Storage reference to the CashModuleStorage
     * @param cashbacks Array of Cashback struct 
     */
    function _cashback(CashModuleStorage storage $, address safe, uint256 spendAmount, Cashback[] calldata cashbacks) internal {
        uint256 len = cashbacks.length;
        
        for (uint256 i = 0; i < len; ) {
            address to = cashbacks[i].to;
            if (to == address(0)) continue;
            CashbackTokens[] memory cashbackTokens = cashbacks[i].cashbackTokens;

            for(uint256 j = 0; j < cashbackTokens.length; ) {
                address token = cashbackTokens[j].token;
                _retrievePendingCashback(to, token);
                
                uint256 amountInUsd = cashbackTokens[j].amountInUsd;
                $.safeCashConfig[to].totalCashbackEarnedInUsd += amountInUsd;
                
                if (amountInUsd != 0) {
                    try $.cashbackDispatcher.cashback(to, token, amountInUsd) returns (uint256 cashbackAmountInToken, bool paid) {
                        if (!paid) $.pendingCashbackForTokenInUsd[to][token] += amountInUsd;
                        $.cashEventEmitter.emitCashbackEvent(safe, spendAmount, to, token, cashbackAmountInToken, amountInUsd, cashbackTokens[j].cashbackType, paid);
                    } catch {
                        $.pendingCashbackForTokenInUsd[to][token] += amountInUsd;
                        $.cashEventEmitter.emitCashbackEvent(safe, spendAmount, to, token, 0, amountInUsd, cashbackTokens[j].cashbackType, false);
                    }
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
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
