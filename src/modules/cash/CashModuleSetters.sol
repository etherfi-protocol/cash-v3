// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import { EnumerableAddressWhitelistLib } from "../../libraries/EnumerableAddressWhitelistLib.sol";
import { IPendingHoldsModule } from "../../interfaces/IPendingHoldsModule.sol";


/**
 * @title CashModule
 * @notice Cash features for EtherFi Safe accounts
 * @author ether.fi
 */
contract CashModuleSetters is CashModuleStorageContract {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using SpendingLimitLib for SpendingLimit;
    using ArrayDeDupLib for address[];

    constructor(address _etherFiDataProvider) CashModuleStorageContract(_etherFiDataProvider) { 
        _disableInitializers();
    }

    /**
     * @notice Sets the settlement dispatcher address for a bin sponsor
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE
     * @param binSponsor Bin sponsor for which the settlement dispatcher is updated
     * @param dispatcher Address of the new settlement dispatcher for the bin sponsor
     * @custom:throws InvalidInput if caller doesn't have the controller role
     */
    function setSettlementDispatcher(BinSponsor binSponsor, address dispatcher) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();
        if (dispatcher == address(0)) revert InvalidInput();

        CashModuleStorage storage $ = _getCashModuleStorage();

        if (binSponsor == BinSponsor.Rain) { 
            $.cashEventEmitter.emitSettlementDispatcherUpdated(binSponsor, $.settlementDispatcherRain, dispatcher);
            $.settlementDispatcherRain = dispatcher;
        } else if (binSponsor == BinSponsor.PIX) {
            $.cashEventEmitter.emitSettlementDispatcherUpdated(binSponsor, $.settlementDispatcherPix, dispatcher);
            $.settlementDispatcherPix = dispatcher;
        } else if (binSponsor == BinSponsor.CardOrder) {
            $.cashEventEmitter.emitSettlementDispatcherUpdated(binSponsor, $.settlementDispatcherCardOrder, dispatcher);
            $.settlementDispatcherCardOrder = dispatcher;
        } else {
            $.cashEventEmitter.emitSettlementDispatcherUpdated(binSponsor, $.settlementDispatcherReap, dispatcher);
            $.settlementDispatcherReap = dispatcher;
        }
    }   

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
    function configureWithdrawAssets(address[] calldata assets, bool[] calldata shouldWhitelist) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();

        CashModuleStorage storage $ = _getCashModuleStorage();

        EnumerableAddressWhitelistLib.configure($.whitelistedWithdrawAssets, assets, shouldWhitelist);
        $.cashEventEmitter.emitWithdrawTokensConfigured(assets, shouldWhitelist);
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
     * @notice Sets the operating mode for a safe
     * @dev Switches between Debit and Credit modes with delay 
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
            $.safeCashConfig[safe].incomingModeStartTime = block.timestamp + $.modeDelay;
            $.safeCashConfig[safe].incomingMode = mode;
            $.cashEventEmitter.emitSetMode(safe, $.safeCashConfig[safe].mode, mode, $.safeCashConfig[safe].incomingModeStartTime);
        }
    }

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
    function requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        CashVerificationLib.verifyRequestWithdrawalSig(safe, IEtherFiSafe(safe).useNonce(), tokens, amounts, recipient, signers, signatures);

        if (_getCashModuleStorage().whitelistedModulesCanRequestWithdraw.contains(msg.sender) || _getCashModuleStorage().whitelistedModulesCanRequestWithdraw.contains(recipient))  revert InvalidWithdrawRequest();
        _requestWithdrawal(safe, tokens, amounts, recipient);
    }

    /**
     * @notice Requests a withdrawal of a token by a module on behalf of a safe
     * @dev Can only be called by whitelisted modules
     * @param safe Address of the EtherFi Safe
     * @param token Token address to withdraw
     * @param amount Token amount to withdraw
     * @custom:throws OnlyEtherFiSafe if the caller is not a valid EtherFi Safe
     * @custom:throws OnlyWhitelistedModuleCanRequestWithdraw if the caller is not a whitelisted module
     */
    function requestWithdrawalByModule(address safe, address token, uint256 amount) external nonReentrant onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();

        if (!etherFiDataProvider.isWhitelistedModule(msg.sender)) revert ModuleNotWhitelistedOnDataProvider();
        if (!$.whitelistedModulesCanRequestWithdraw.contains(msg.sender)) revert OnlyWhitelistedModuleCanRequestWithdraw();

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = token;
        amounts[0] = amount;

        address recipient = msg.sender; // The module itself is the recipient
        
        _requestWithdrawal(safe, tokens, amounts, recipient);
    }

    /**
     * @notice Configures which modules can request withdrawals
     * @dev Can only be called by the CASH_MODULE_CONTROLLER_ROLE
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of boolean values indicating whether to whitelist each module
     */
    function configureModulesCanRequestWithdraw(address[] calldata modules, bool[] calldata shouldWhitelist) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();

        CashModuleStorage storage $ = _getCashModuleStorage();

        uint256 len = modules.length;
        if (len == 0 || len != shouldWhitelist.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len; ) {
            if (shouldWhitelist[i] && !etherFiDataProvider.isWhitelistedModule(modules[i])) revert ModuleNotWhitelistedOnDataProvider();
            unchecked {
                ++i;
            }
        }

        EnumerableAddressWhitelistLib.configure($.whitelistedModulesCanRequestWithdraw, modules, shouldWhitelist);
        $.cashEventEmitter.emitModulesCanRequestWithdrawConfigured(modules, shouldWhitelist);
    }

    /**
     * @notice Cancel a pending withdrawal request
     * @dev Only callable by the module that requested the withdrawal if requested by a whitelisted module
     * @param safe Address of the EtherFi Safe
     * @param signers Array of signers for the cancellation
     * @param signatures Array of signatures from the signers
     */
    function cancelWithdrawal(address safe, address[] calldata signers, bytes[] calldata signatures) external onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage $$ = $.safeCashConfig[safe];

        if ($$.pendingWithdrawalRequest.tokens.length == 0) revert WithdrawalDoesNotExist();

        // Ensure that the module that requested the withdrawal is the one cancelling it
        if ($.whitelistedModulesCanRequestWithdraw.contains($$.pendingWithdrawalRequest.recipient)) revert InvalidWithdrawRequest();

        CashVerificationLib.verifyCancelWithdrawalSig(safe, IEtherFiSafe(safe).useNonce(), signers, signatures);
        _cancelOldWithdrawal(safe);
    }

    /**
     * @notice Cancels a pending withdrawal request by the module
     * @dev Only callable by whitelisted modules that requested the withdrawal
     * @param safe Address of the EtherFi Safe
     */
    function cancelWithdrawalByModule(address safe) external onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage $$ = $.safeCashConfig[safe];

        if ($$.pendingWithdrawalRequest.tokens.length == 0) revert WithdrawalDoesNotExist();
        if (!$.whitelistedModulesCanRequestWithdraw.contains($$.pendingWithdrawalRequest.recipient)) revert InvalidWithdrawRequest(); 
        if (msg.sender != $$.pendingWithdrawalRequest.recipient) revert OnlyModuleThatRequestedCanCancel();
        if (!etherFiDataProvider.isWhitelistedModule(msg.sender)) revert ModuleNotWhitelistedOnDataProvider();
        
        _cancelOldWithdrawal(safe);
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
     * @notice Checks if a safe has sufficient balance for all tokens and amounts
     * @dev Called before creating a withdrawal request to prevent invalid requests
     * @param safe Address of the EtherFi Safe
     * @param tokens Array of token addresses to check
     * @param amounts Array of token amounts to check
     * @custom:throws ArrayLengthMismatch if arrays have different lengths
     * @custom:throws InsufficientBalance if any token has insufficient balance
     */
    function _checkBalance(address safe, address[] memory tokens, uint256[] memory amounts) internal view {
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
     */
function _requestWithdrawal(address safe, address[] memory tokens, uint256[] memory amounts, address recipient) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage $$ = $.safeCashConfig[safe];

        if (recipient == address(0)) revert RecipientCannotBeAddressZero();
        if (tokens.length > 1) tokens.checkDuplicates();

        // Block withdrawals while pending holds exist — the safe's balance is committed to unsettled card txns
        address phm = $.pendingHoldsModule;
        if (phm != address(0) && IPendingHoldsModule(phm).totalPendingHolds(safe) > 0) revert WithdrawalBlockedByPendingHolds();

        _areAssetsWithdrawable($, tokens);
        _cancelOldWithdrawal(safe);

        uint96 finalTime = uint96(block.timestamp) + $.withdrawalDelay;

        _checkBalance(safe, tokens, amounts);

        $$.pendingWithdrawalRequest = WithdrawalRequest({ tokens: tokens, amounts: amounts, recipient: recipient, finalizeTime: finalTime });
        $.cashEventEmitter.emitWithdrawalRequested(safe, tokens, amounts, recipient, finalTime);

        _getDebtManager().ensureHealth(safe);

        if ($.withdrawalDelay == 0) _processWithdrawal(safe);
    }

    // -------------------------------------------------------------------------
    // Repayment — moved here from CashModuleCore to preserve Core's 24KB ceiling
    // -------------------------------------------------------------------------

    /**
     * @notice Repays borrowed tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses.
     *      Routed from Core via fallback() delegatecall.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws OnlyBorrowToken if token is not a valid borrow token
     */
    function repay(address safe, address token, uint256 amountInUsd) public whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        IDebtManager debtManager = _getDebtManager();
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
        _cancelWithdrawalRequestIfNecessary(safe, token, amount);

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

    // -------------------------------------------------------------------------
    // PendingHoldsModule integration
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the remaining spendable capacity for a safe based on its spending limits
     * @dev Returns min(remainingDailyLimit, remainingMonthlyLimit) in USD (1e6).
     *      When PendingHoldsModule is active, holds are charged to spentToday/spentThisMonth at
     *      addHold() time, so this value already reflects in-flight hold consumption.
     *      Lives here (not in Core) to preserve Core's EVM 24KB bytecode ceiling.
     *      Routed transparently via Core's fallback() delegatecall.
     * @param safe Address of the EtherFi Safe
     * @return Spendable amount in USD (1e6)
     */
    function rawSpendable(address safe) external view returns (uint256) {
        return _getCashModuleStorage().safeCashConfig[safe].spendingLimit.maxCanSpend();
    }

    /**
     * @notice Consumes amountUsd from the safe's daily and monthly spending limits
     * @dev Called by PendingHoldsModule at addHold() and updateHold() (increase) so that
     *      the limit reflects the user's authorized spend immediately at auth-ack time.
     *      Reverts with ExceededDailySpendingLimit or ExceededMonthlySpendingLimit if the
     *      amount would breach the limit — identical validation to the settlement-time spend().
     *      Only callable by the registered PendingHoldsModule.
     *      Lives here (not in Core) to preserve Core's EVM 24KB bytecode ceiling.
     * @param safe Address of the EtherFi Safe
     * @param amountUsd Amount to consume from limits in USD (1e6)
     */
    function consumeSpendingLimit(address safe, uint256 amountUsd) external {
        if (msg.sender != _getCashModuleStorage().pendingHoldsModule) revert InvalidInput();
        _getCashModuleStorage().safeCashConfig[safe].spendingLimit.spend(amountUsd);
    }

    /**
     * @notice Credits amountUsd back to the safe's daily and monthly spending limits
     * @dev Called by PendingHoldsModule at releaseHold() and updateHold() (decrease) to
     *      return limit headroom when an authorized transaction is reversed or downsized.
     *      Applies a floor at 0 on each counter — safe for day/month-boundary crossings where
     *      the counter already reset to 0 before the credit arrives.
     *      Only callable by the registered PendingHoldsModule.
     *      Lives here (not in Core) to preserve Core's EVM 24KB bytecode ceiling.
     * @param safe Address of the EtherFi Safe
     * @param amountUsd Amount to release from limits in USD (1e6)
     */
    function releaseSpendingLimit(address safe, uint256 amountUsd) external {
        if (msg.sender != _getCashModuleStorage().pendingHoldsModule) revert InvalidInput();
        _getCashModuleStorage().safeCashConfig[safe].spendingLimit.release(amountUsd);
    }

    /**
     * @notice Sets the PendingHoldsModule address
     * @dev Only callable by accounts with CASH_MODULE_CONTROLLER_ROLE.
     * @param _pendingHoldsModule Address of the deployed PendingHoldsModule proxy
     */
    function setPendingHoldsModule(address _pendingHoldsModule) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();
        if (_pendingHoldsModule == address(0)) revert InvalidInput();
        _getCashModuleStorage().pendingHoldsModule = _pendingHoldsModule;
    }

    /**
     * @notice Collects the outstanding remainder of an under-funded settlement from the safe's balance.
     * @dev When spend() settled a transaction the safe could not fully cover, the unpaid remainder is
     *      parked in a forced "remaining" hold (see CashModuleCore._phmFinalize). This lets ops sweep
     *      that remainder once the safe is funded: it pays up to the outstanding remainder from `token`,
     *      reduces the hold, and removes it (unblocking withdrawals) once fully paid.
     *
     *      The spending limit is NOT charged again — the full settlement amount was already charged at
     *      the original spend(). Only operates on already-settled transactions (transactionCleared == true),
     *      which distinguishes a post-settlement debt from a pre-settlement forceAddHold hold.
     *
     *      Lives here (not in Core) to preserve Core's EVM 24KB bytecode ceiling; routed via fallback().
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier (the original authorization/settlement id)
     * @param binSponsor Bin sponsor the settlement was made under
     * @param token Borrow token to collect the remainder from
     * @custom:throws InvalidInput if PHM unset, txId not yet settled, or no remainder outstanding
     * @custom:throws UnsupportedToken if token is not a borrow token
     * @custom:throws InsufficientBalance if the safe holds nothing collectable in token
     */
    function collectRemaining(address safe, bytes32 txId, BinSponsor binSponsor, address token)
        external
        whenNotPaused
        nonReentrant
        onlyEtherFiWallet
        onlyEtherFiSafe(safe)
    {
        CashModuleStorage storage $ = _getCashModuleStorage();
        address phm = $.pendingHoldsModule;
        if (phm == address(0)) revert InvalidInput();
        // Must be a post-settlement debt, not a pre-settlement forceAddHold hold awaiting spend().
        if (!$.safeCashConfig[safe].transactionCleared[txId]) revert InvalidInput();
        if (!_isBorrowToken($.debtManager, token)) revert UnsupportedToken();

        uint256 remaining = IPendingHoldsModule(phm).remainingHold(safe, binSponsor, txId);
        if (remaining == 0) revert InvalidInput();

        (uint256 payToken, uint256 paidUsd) = _collectAmounts($, safe, token, remaining);

        _cancelWithdrawalRequestIfNecessary(safe, token, payToken);
        _collectTransferAndEmit($, safe, binSponsor, txId, token, payToken, paidUsd);

        // Reduce or clear the hold. No limit charge — already charged at the original settlement.
        if (remaining - paidUsd == 0) IPendingHoldsModule(phm).removeHold(safe, binSponsor, txId);
        else IPendingHoldsModule(phm).settlementSetRemainingHold(safe, binSponsor, txId, remaining - paidUsd);

        $.debtManager.ensureHealth(safe);
    }

    /// @dev Computes how much of `remaining` (USD 1e6) can be collected from the safe's `token` balance.
    ///      Rounds USD down (favors the safe). Reverts if nothing meaningful is collectable.
    function _collectAmounts(CashModuleStorage storage $, address safe, address token, uint256 remaining)
        private
        view
        returns (uint256 payToken, uint256 paidUsd)
    {
        uint256 required = $.debtManager.convertUsdToCollateralToken(token, remaining);
        if (required == 0) revert AmountZero();
        uint256 available = IERC20(token).balanceOf(safe);
        if (available < required) {
            payToken = available;
            paidUsd = remaining * available / required; // round down — never over-credits the debt
        } else {
            payToken = required;
            paidUsd = remaining;
        }
        // Refuse a transfer that would move tokens without reducing the recorded debt (dust guard).
        if (paidUsd == 0) revert InsufficientBalance();
    }

    /// @dev Transfers the collected tokens to the settlement dispatcher and emits a Spend event.
    function _collectTransferAndEmit(
        CashModuleStorage storage $,
        address safe,
        BinSponsor binSponsor,
        bytes32 txId,
        address token,
        uint256 payToken,
        uint256 paidUsd
    ) private {
        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = token;
        data[0] = abi.encodeWithSelector(IERC20.transfer.selector, _settlementDispatcherFor($, binSponsor), payToken);
        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](1), data);

        uint256[] memory tokenAmounts = new uint256[](1);
        uint256[] memory usdAmounts = new uint256[](1);
        tokenAmounts[0] = payToken;
        usdAmounts[0] = paidUsd;
        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, to, tokenAmounts, usdAmounts, paidUsd, Mode.Debit);
    }

    /// @dev Resolves the settlement dispatcher for a bin sponsor (mirrors CashModuleCore.getSettlementDispatcher).
    function _settlementDispatcherFor(CashModuleStorage storage $, BinSponsor binSponsor) private view returns (address dispatcher) {
        if (binSponsor == BinSponsor.Rain) dispatcher = $.settlementDispatcherRain;
        else if (binSponsor == BinSponsor.PIX) dispatcher = $.settlementDispatcherPix;
        else if (binSponsor == BinSponsor.CardOrder) dispatcher = $.settlementDispatcherCardOrder;
        else dispatcher = $.settlementDispatcherReap;
        if (dispatcher == address(0)) revert SettlementDispatcherNotSetForBinSponsor();
    }
}
