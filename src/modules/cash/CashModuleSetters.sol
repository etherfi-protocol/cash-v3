// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

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
    function requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, address[] calldata signers, bytes[] calldata signatures) external onlyEtherFiSafe(safe) {
        CashVerificationLib.verifyRequestWithdrawalSig(safe, IEtherFiSafe(safe).useNonce(), tokens, amounts, recipient, signers, signatures);
        _requestWithdrawal(safe, tokens, amounts, recipient);
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
     */
    function _requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage $$ = $.safeCashConfig[safe];

        if (recipient == address(0)) revert RecipientCannotBeAddressZero();
        if (tokens.length > 1) tokens.checkDuplicates();

        _cancelOldWithdrawal(safe);

        uint96 finalTime = uint96(block.timestamp) + $.withdrawalDelay;

        _checkBalance(safe, tokens, amounts);

        $$.pendingWithdrawalRequest = WithdrawalRequest({ tokens: tokens, amounts: amounts, recipient: recipient, finalizeTime: finalTime });
        $.cashEventEmitter.emitWithdrawalRequested(safe, tokens, amounts, recipient, finalTime);

        _getDebtManager().ensureHealth(safe);

        if ($.withdrawalDelay == 0) _processWithdrawal(safe);
    }
}
