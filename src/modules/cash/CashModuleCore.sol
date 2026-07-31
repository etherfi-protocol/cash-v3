// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ICashEventEmitter } from "../../interfaces/ICashEventEmitter.sol";
import { BinSponsor, Cashback, CashbackTokens, Mode, SafeCashConfig, SafeData, SafeTiers, TokenDataInUsd, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { ICashbackDispatcher } from "../../interfaces/ICashbackDispatcher.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ILendGateway } from "../../interfaces/ILendGateway.sol";
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";
import { CashVerificationLib } from "../../libraries/CashVerificationLib.sol";
import { SignatureUtils } from "../../libraries/SignatureUtils.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { IPendingHoldsModule } from "../../interfaces/IPendingHoldsModule.sol";
import { CashLendLib } from "./CashLendLib.sol";
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
     * @dev Creates default spending limits and sets initial mode to Debit with 50% cashback split. The backend
     *      picks the engine per safe at deploy time via the useLendGateway flag in the setup data.
     * @param data ABI-encoded (uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, int256 timezoneOffset, bool useLendGateway)
     */
    function setupModule(bytes calldata data) external override onlyEtherFiSafe(msg.sender) {
        (uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, int256 timezoneOffset, bool useLendGateway) = abi.decode(data, (uint256, uint256, int256, bool));

        CashModuleStorage storage cashStorage = _getCashModuleStorage();
        SafeCashConfig storage $ = cashStorage.safeCashConfig[msg.sender];
        $.spendingLimit.initialize(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);
        $.mode = Mode.Debit;

        // The backend decides the engine per safe. When useLendGateway is set the safe onboards onto the Aave
        // gateway; otherwise it stays on the legacy DebtManager. The legacyDebtUsd guard keeps a safe with open
        // DebtManager debt on DebtManager until migrateToLendGateway moves its position, since setupModule is
        // re-runnable.
        if (useLendGateway) {
            if (address(cashStorage.gateway) == address(0)) revert LendGatewayNotSet();
            (, uint256 legacyDebtUsd) = _getDebtManager().borrowingOf(msg.sender);
            if (legacyDebtUsd == 0) $.usesLendGateway = true;
        }
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

        for (uint256 i = 0; i < len;) {
            uint256 pendingCashbackInUsd = $.pendingCashbackForTokenInUsd[account][tokens[i]];
            if (pendingCashbackInUsd > 0) {
                data[m] = TokenDataInUsd({ token: tokens[i], amountInUsd: pendingCashbackInUsd });

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
    function getSettlementDispatcher(BinSponsor binSponsor) public view returns (address) {
        return CashLendLib.settlementDispatcher(_getCashModuleStorage(), binSponsor);
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
        CashLendLib.postLiquidateTransfers(safe, liquidator, tokensToSend);
    }

    /**
     * @notice Whether lend is live for a safe: on the Aave gateway engine and not opted out. This is the
     *         predicate every lend action and module sandwich gates on.
     * @param safe Address of the EtherFi Safe
     * @return True if the safe uses the gateway engine and has not opted out
     */
    function isLendActive(address safe) external view returns (bool) {
        return _usesLendGateway(safe) && !CashLendLib.isLendOptedOut(_getCashModuleStorage(), safe);
    }

    /**
     * @notice The user's effective lend opt-out state, independent of the safe's engine
     * @dev The gateway's supply/collateral gates read this (not isLendActive), since a safe is supplied into
     *      Aave during migration before its engine flag flips. Effective: a pending opt-out whose finalize
     *      time has passed reports true even before processLendOptOut runs, mirroring how getMode honors a
     *      matured incoming mode.
     * @param safe Address of the EtherFi Safe
     * @return True if the safe opted out via toggleLend(false), processed or matured-pending
     */
    function isLendOptedOut(address safe) external view returns (bool) {
        return CashLendLib.isLendOptedOut(_getCashModuleStorage(), safe);
    }

    /**
     * @notice Whether the safe's borrow/collateral engine is the Aave gateway (vs the legacy DebtManager)
     * @dev The canonical routing flag; see ICashModule.usesLendGateway
     * @param safe Address of the EtherFi Safe
     * @return True if the safe uses the Aave gateway
     */
    function usesLendGateway(address safe) external view returns (bool) {
        return _usesLendGateway(safe);
    }

    /**
     * @notice Returns the timestamp when a pending lend opt-out request becomes executable
     * @dev Returns 0 if no opt-out is pending
     * @param safe Address of the EtherFi Safe
     * @return Timestamp when processLendOptOut may be called, or 0 if none pending
     */
    function lendOptOutFinalizeTime(address safe) external view returns (uint256) {
        return _getCashModuleStorage().safeCashConfig[safe].lendOptOutFinalizeTime;
    }

    /**
     * @notice Returns the configured Aave gateway used for lend operations
     * @return LendGateway instance (zero if not set)
     */
    function getLendGateway() external view returns (ILendGateway) {
        return _getCashModuleStorage().gateway;
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
     * @notice Executes a pending lend opt-out request (from toggleLend(false)) after its delay has elapsed
     * @dev Permissionless once the delay has elapsed. Withdraws all Aave collateral back to the safe, marks
     *      the safe opted out, and forces it into Debit mode. Re-checks that the safe has no open borrows so
     *      a borrow taken during the delay window cannot strand collateral.
     * @param safe Address of the EtherFi Safe
     * @custom:throws OnlyEtherFiSafe if safe is not a valid EtherFi Safe
     * @custom:throws NoPendingLendOptOut if no disable request is pending
     * @custom:throws LendOptOutNotReady if the delay period hasn't passed
     * @custom:throws HasOpenBorrows if the safe borrowed during the delay window
     */
    function processLendOptOut(address safe) external onlyEtherFiSafe(safe) nonReentrant {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage safeConfig = $.safeCashConfig[safe];
        if (safeConfig.lendOptOutFinalizeTime == 0) revert NoPendingLendOptOut();
        if (block.timestamp <= safeConfig.lendOptOutFinalizeTime) revert LendOptOutNotReady();
        if (CashLendLib.hasOpenBorrows($, safe)) revert HasOpenBorrows();
        CashLendLib.executeLendOptOut($, safe);
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

        // A matured opt-out takes effect before the spend routes: it forces Debit mode (and unwinds the
        // Aave position), so this must run before _validateSpend reads the mode.
        CashLendLib.processLendOptOutIfReady($, safe);

        uint256 totalSpendingInUsd = _validateSpend($.safeCashConfig[safe], txId, tokens, amountsInUsd);

        // Sync hold to settlement amount (or create forced hold). Handle limit delta in Core to
        // avoid a PHM->Core callback re-entering the nonReentrant spend() context.
        _phmSettleHold($, safe, binSponsor, txId, totalSpendingInUsd);

        uint256 actualSpendInUsd = _routeSpend($, safe, txId, binSponsor, tokens, amountsInUsd, totalSpendingInUsd);

        _phmFinalize($, safe, binSponsor, txId, totalSpendingInUsd, actualSpendInUsd);
        _cashback($, safe, actualSpendInUsd, cashbacks);
    }

    /**
     * @dev Routes the settlement by mode and returns the USD it actually moved. Its own stack frame keeps
     *      spend() clear of the legacy stack limit.
     *
     *      CashLendLib routes each mode by engine (Aave gateway vs legacy DebtManager) and emits Spend.
     *      A debit may settle partially when the safe is under-funded and the holds registry can carry the
     *      remainder as on-chain debt; with no registry configured a debit must still settle in full.
     */
    function _routeSpend(CashModuleStorage storage $, address safe, bytes32 txId, BinSponsor binSponsor, address[] calldata tokens, uint256[] calldata amountsInUsd, uint256 totalSpendingInUsd) private returns (uint256) {
        if ($.safeCashConfig[safe].mode == Mode.Credit) {
            CashLendLib.spendCredit($, etherFiDataProvider, safe, txId, binSponsor, tokens, amountsInUsd, totalSpendingInUsd);
            return totalSpendingInUsd;
        }
        return CashLendLib.spendDebit($, etherFiDataProvider, safe, txId, binSponsor, tokens, amountsInUsd);
    }

    function _validateSpend(SafeCashConfig storage $$, bytes32 txId, address[] calldata tokens, uint256[] calldata amountsInUsd) internal returns (uint256) {
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
     *        - No hold existed (Settlement is KING): charge full settlement to limit now (the
     *                                               forced hold created at sync bypassed it).
     *        - Forced hold (forceAddHold path):     charge full settlement to limit now,
     *                                               since limit was bypassed at forceAddHold.
     *        - Non-forced hold, settlement > old:   charge delta to limit.
     *        - Non-forced hold, settlement < old:   release delta from limit.
     *        - Non-forced hold, settlement == old:  no-op.
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
        // The limit already reflects `oldCharged` for this obligation; make it reflect `amount`.
        //   - non-forced hold: limit was pre-charged at addHold for oldAmount → reconcile the delta.
        //   - forced hold / no prior hold ("Settlement is KING"): limit was bypassed at creation
        //     (oldCharged = 0) → reconcileLimit charges the full settlement amount now.
        uint256 oldCharged = (existed && !wasForced) ? oldAmount : 0;
        $.safeCashConfig[safe].spendingLimit.reconcileLimit(oldCharged, amount);
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
     * @notice Clears pending cashback for users
     * @param users Addresses of users to clear the pending cashback for
     * @param tokens Addresses of cashback tokens
     */
    function clearPendingCashback(address[] calldata users, address[] calldata tokens) external nonReentrant whenNotPaused {
        uint256 len = users.length;
        if (len == 0) revert InvalidInput();
        if (tokens.length > 1) tokens.checkDuplicates();
        if (len > 1) users.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (users[i] == address(0)) revert InvalidInput();

            for (uint256 j = 0; j < tokens.length;) {
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
            } catch { }
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

        for (uint256 i = 0; i < len;) {
            address to = cashbacks[i].to;
            if (to == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }
            CashbackTokens[] memory cashbackTokens = cashbacks[i].cashbackTokens;

            for (uint256 j = 0; j < cashbackTokens.length;) {
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
     * @notice Repays borrowed tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses. CashLendLib routes by engine
     *      and owns the token check, USD conversion, and withdrawal-reservation handling for both.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws OnlyBorrowToken if the token cannot carry debt on the safe's engine
     */
    function repay(address safe, address token, uint256 amountInUsd) public whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        CashLendLib.repay($, etherFiDataProvider, safe, token, amountInUsd);
        // A repay can clear the open borrows that were blocking a matured opt-out from processing
        CashLendLib.processLendOptOutIfReady($, safe);
    }

    /**
     * @notice Repays Aave debt in token units without reading the Cash PriceProvider
     * @dev This is intentionally restricted to safes on the lend gateway. Legacy DebtManager repayment
     *      remains USD-denominated and unchanged.
     * @param safe Address of the EtherFi Safe whose debt is repaid.
     * @param token Address of the debt token.
     * @param amount Maximum amount to repay in token units.
     * @custom:throws OnlyLendGatewaySafe if the safe still uses DebtManager.
     * @custom:throws OnlyBorrowToken if the token is not registered on the gateway.
     * @custom:throws AmountZero if the amount or live debt is zero.
     */
    function repayLendTokenAmount(address safe, address token, uint256 amount) external whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        CashLendLib.repayLendTokenAmount($, etherFiDataProvider, safe, token, amount);
        CashLendLib.processLendOptOutIfReady($, safe);
    }

    /**
     * @notice Supplies a safe's loose token balances into the Aave lend market (the auto-supply sweep)
     * @dev Only callable by the EtherFi wallet (the cash-be sweeper). Per token: supplies the loose balance
     *      net of any pending-withdrawal reservation and flags it as collateral; zero and unregistered
     *      tokens are skipped. No-op for an opted-out safe; reverts for a legacy safe.
     * @param safe Address of the EtherFi Safe
     * @param tokens Tokens to sweep
     * @custom:throws OnlyLendGatewaySafe if the safe runs on the legacy DebtManager engine
     */
    function supplyToLend(address safe, address[] calldata tokens) external whenNotPaused nonReentrant onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashLendLib.supplyToLend(_getCashModuleStorage(), safe, tokens);
    }

    /**
     * @notice Borrows a token against the safe's lend-market position; the proceeds land in the safe and
     *         are immediately supplied back as collateral
     * @dev Owner-quorum signed: the signatures bind the token and USD amount so neither a compromised backend
     *      nor a single compromised admin can lever a safe up. Any relayer may submit the signed intent. Aave
     *      enforces the health check on the borrow itself.
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to borrow
     * @param amountInUsd Amount to borrow in USD
     * @param signers Addresses of the owners authorizing the borrow
     * @param signatures The signers' signatures over the intent
     * @custom:throws InvalidSignatures if the signatures do not meet the owner quorum
     * @custom:throws OnlyBorrowToken if token is not borrowable on the gateway
     * @custom:throws AmountZero if the converted amount is zero
     * @custom:throws OnlyLendGatewaySafe if the safe runs on the legacy DebtManager engine
     */
    function borrow(address safe, address token, uint256 amountInUsd, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused nonReentrant onlyEtherFiSafe(safe) {
        CashLendLib.borrow(_getCashModuleStorage(), etherFiDataProvider, safe, token, amountInUsd, IEtherFiSafe(safe).useNonce(), signers, signatures);
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
