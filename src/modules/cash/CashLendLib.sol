// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BinSponsor, Mode, SafeCashConfig, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IGateway } from "../../interfaces/IGateway.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { DebitSourcingLib } from "../../libraries/DebitSourcingLib.sol";
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashLendLib
 * @notice The CashModule's lend logic: every module operation that touches the Aave gateway or the safe's
 *         position. It holds credit spending, debit-spend sourcing against the supplied balance, debt
 *         repayment, and the lend enable/disable lifecycle. CashModuleCore and CashModuleSetters keep only
 *         the thin entrypoints (access control, signature checks, events wiring) and delegate the work here.
 * @dev Deployed once and linked into CashModuleCore and CashModuleSetters, so this logic does not count
 *      against either implementation's EIP-170 runtime code-size limit. Every function is called via
 *      delegatecall and therefore runs in the CashModule's storage context: the caller passes its
 *      CashModuleStorage pointer and the library reads and writes the same namespaced storage the module
 *      would. Two consequences of the delegatecall shape: functions that need the module's
 *      etherFiDataProvider immutable take it as a parameter, and functions that would cancel the pending
 *      withdrawal request return a flag instead, since the cancel helper is module-internal.
 * @author ether.fi
 */
library CashLendLib {
    // These mirror CashModule's own errors selector-for-selector, so reverts from the library are
    // indistinguishable from reverts thrown in the module itself.
    error LendGatewayNotSet();
    error UnsupportedToken();
    error InsufficientBalance();
    error LendAlreadyDisabled();
    error HasOpenBorrows();
    error LendNotDisabled();
    error LendDisabled();
    error AmountZero();

    // Threads a debit spend's cross-token state through the sizing pass. Bundled into one struct so the
    // sizing frames stay well under the legacy stack limit (the price provider is a parameter here, where in
    // the module it was a free immutable).
    struct DebitSpendState {
        uint256[] amounts; // token amount sourced per token
        uint256[] fromLoose; // portion of each amount taken from the safe's loose balance
        uint256 borrowHeadroom; // remaining USD borrowing headroom, consumed as supplied balance is drawn
        bool hasDebt; // whether the safe carries debt (the headroom cap only applies then)
        bool dipped; // whether sizing dipped into withdrawal-reserved balance (caller must cancel the request)
    }

    /**
     * @notice Executes a repayment on behalf of a safe, routing by migration state
     * @dev The caller must have already validated the amount and cancelled any conflicting withdrawal request.
     *      A migrated safe repays on Aave via the gateway (which pulls the token from the safe, repays, refunds
     *      dust, and emits Repaid); a legacy safe repays the DebtManager through the safe's module execution.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe The safe whose debt is repaid
     * @param token The token to repay
     * @param amount The token amount to repay
     * @param amountInUsd The USD value of the repayment (for the emitted DebtManager event)
     * @custom:throws LendGatewayNotSet if the safe is migrated but no gateway is configured
     */
    function repay(CashModuleStorageContract.CashModuleStorage storage $, address safe, address token, uint256 amount, uint256 amountInUsd) external {
        if ($.debtManager.hasMigratedToAave(safe)) {
            IGateway gateway = $.gateway;
            if (address(gateway) == address(0)) revert LendGatewayNotSet();
            // Full repays pass the max sentinel so no interest dust survives the exact-amount rounding.
            uint256 debt = gateway.debtOf(safe, token);
            uint256 repaid = gateway.repay(safe, token, amount >= debt ? type(uint256).max : amount);
            // The gateway may repay less than requested (dust refund, or the live Aave debt being smaller than
            // the quote), so report the USD value of what was actually repaid, not the requested amount.
            uint256 repaidInUsd = repaid == amount ? amountInUsd : $.debtManager.convertCollateralTokenToUsd(token, repaid);
            $.cashEventEmitter.emitRepay(safe, token, repaid, repaidInUsd);
            return;
        }

        address[] memory to = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        to[0] = token;
        to[1] = address($.debtManager);
        to[2] = token;

        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address($.debtManager), amount);
        data[1] = abi.encodeWithSelector(IDebtManager.repay.selector, safe, token, amount);
        data[2] = abi.encodeWithSelector(IERC20.approve.selector, address($.debtManager), 0);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        $.cashEventEmitter.emitRepayDebtManager(safe, token, amount, amountInUsd);
    }

    /**
     * @notice Whether a safe has any open borrows (Aave debt via the gateway, or legacy DebtManager debt)
     * @dev Checks raw per-asset debt, not getAccountData().debtUsd: the USD aggregate floors to 6 decimals,
     *      so sub-$0.000001 dust reads as zero here and then reverts deep in Aave when disableLend tries to
     *      withdraw all collateral.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function hasOpenBorrows(CashModuleStorageContract.CashModuleStorage storage $, address safe) public view returns (bool) {
        IGateway gateway = $.gateway;
        if (address(gateway) != address(0)) {
            address[] memory assets = gateway.registeredAssets();
            uint256 aLen = assets.length;
            for (uint256 i = 0; i < aLen;) {
                if (gateway.debtOf(safe, assets[i]) != 0) return true;
                unchecked {
                    ++i;
                }
            }
        }
        (, uint256 debtManagerDebt) = $.debtManager.borrowingOf(safe);
        return debtManagerDebt != 0;
    }

    /**
     * @notice Records a request to disable lend for a safe (executable after modeDelay)
     * @dev Reverts if lend is already disabled/pending or the safe has open borrows. Executes immediately
     *      if the delay is zero.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function requestDisableLend(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];

        if ($$.lendDisabled || $$.lendDisableFinalizeTime != 0) revert LendAlreadyDisabled();
        if (hasOpenBorrows($, safe)) revert HasOpenBorrows();

        uint96 finalizeTime = uint96(block.timestamp) + $.modeDelay;
        $$.lendDisableFinalizeTime = finalizeTime;
        $.cashEventEmitter.emitLendDisableRequested(safe, finalizeTime);

        if ($.modeDelay == 0) disableLend($, safe);
    }

    /**
     * @notice Executes the disable-lend: withdraws ALL of the safe's Aave collateral back to the safe, marks
     *         lend disabled, and forces the safe into Debit mode
     * @dev Iterates the gateway's registered assets, not DebtManager's collateral list, so a token delisted
     *      from DebtManager while still supplied on Aave stays withdrawable. Reverts if the gateway is unset.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function disableLend(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        IGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();

        address[] memory collateralTokens = gateway.registeredAssets();
        uint256 len = collateralTokens.length;
        for (uint256 i = 0; i < len;) {
            uint256 supplied = gateway.suppliedOf(safe, collateralTokens[i]);
            if (supplied != 0) gateway.withdraw(safe, collateralTokens[i], supplied, safe);
            unchecked {
                ++i;
            }
        }

        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        $$.lendDisabled = true;
        $$.lendDisableFinalizeTime = 0;
        // Credit needs lend collateral, so force Debit and drop any pending mode change
        $$.mode = Mode.Debit;
        delete $$.incomingMode;
        delete $$.incomingModeStartTime;

        $.cashEventEmitter.emitLendDisableExecuted(safe);
    }

    /**
     * @notice Re-enables lend for a safe and cancels any pending disable request
     * @dev Instant, since opting back into earning is not risk-increasing. Reverts if lend is already
     *      enabled and no disable is pending.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function enableLend(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        if (!$$.lendDisabled && $$.lendDisableFinalizeTime == 0) revert LendNotDisabled();

        $$.lendDisabled = false;
        $$.lendDisableFinalizeTime = 0;
        $.cashEventEmitter.emitLendEnabled(safe);
    }

    /**
     * @notice Credit spend (single token): borrows against the safe's position and sends the borrowed
     *         token to the settlement dispatcher
     * @dev A migrated safe borrows on Aave via the gateway; a legacy safe borrows from the DebtManager,
     *      executed by the safe itself. A blocked legacy borrow is not retried here: the retry first
     *      cancels the pending withdrawal request, which is module-internal, so the caller cancels and
     *      then calls legacyBorrow.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @param binSponsor Bin sponsor used for spending
     * @param dispatcher Settlement dispatcher receiving the borrowed token
     * @param token Address of the token to spend
     * @param amountInUsd Amount to spend in USD
     * @return The token amount spent
     * @return Whether the caller must cancel the pending withdrawal request and retry via legacyBorrow
     */
    function spendCredit(CashModuleStorageContract.CashModuleStorage storage $, address safe, BinSponsor binSponsor, address dispatcher, address token, uint256 amountInUsd) external returns (uint256, bool) {
        // Defense-in-depth: a safe that opted out of lend is forced to Debit and blocked from re-entering
        // Credit, so credit spending must never reach a lend-disabled safe.
        if ($.safeCashConfig[safe].lendDisabled) revert LendDisabled();
        if (!$.debtManager.isBorrowToken(token)) revert UnsupportedToken();
        uint256 amount = $.debtManager.convertUsdToCollateralToken(token, amountInUsd);
        if (amount == 0) revert AmountZero();

        if ($.debtManager.hasMigratedToAave(safe)) {
            // Migrated safe: its position lives on Aave. Borrow there via the gateway (the CashModule is
            // always a gateway driver) and send the borrowed token straight to the settlement dispatcher.
            // The legacy DebtManager.borrow path reverts for a migrated safe, and CashLens already sizes
            // credit against the gateway, so routing here keeps the on-chain spend consistent with the
            // precheck. Aave enforces the borrowing-power/health check on the borrow itself.
            IGateway gateway = $.gateway;
            if (address(gateway) == address(0)) revert LendGatewayNotSet();
            gateway.borrow(safe, token, amount, dispatcher);
            return (amount, false);
        }

        (address[] memory to, uint256[] memory values, bytes[] memory data) = _legacyBorrowCall($, binSponsor, token, amount);
        try IEtherFiSafe(safe).execTransactionFromModule(to, values, data) {
            return (amount, false);
        } catch {
            return (amount, true);
        }
    }

    /**
     * @notice Executes a legacy DebtManager borrow through the safe's module execution
     * @dev The retry path after spendCredit signalled a blocked borrow and the caller cancelled the
     *      pending withdrawal request
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @param binSponsor Bin sponsor used for spending
     * @param token Address of the token to spend
     * @param amount Token amount to borrow
     */
    function legacyBorrow(CashModuleStorageContract.CashModuleStorage storage $, address safe, BinSponsor binSponsor, address token, uint256 amount) public {
        (address[] memory to, uint256[] memory values, bytes[] memory data) = _legacyBorrowCall($, binSponsor, token, amount);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /// @dev Builds the safe-executed DebtManager.borrow call shared by spendCredit and legacyBorrow.
    function _legacyBorrowCall(CashModuleStorageContract.CashModuleStorage storage $, BinSponsor binSponsor, address token, uint256 amount) private view returns (address[] memory, uint256[] memory, bytes[] memory) {
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        to[0] = address($.debtManager);
        data[0] = abi.encodeWithSelector(IDebtManager.borrow.selector, binSponsor, token, amount);

        return (to, values, data);
    }

    /**
     * @notice Sizes a debit spend across tokens: the safe's loose balance is spent first, then the
     *         Aave-supplied balance covers any shortfall
     * @dev Per token, _sourceDebitToken sizes the loose/supplied split and threads the borrowing headroom
     *      across tokens, so a debit cannot push a debt-carrying safe past its LTV max borrow. Pure sizing:
     *      the caller cancels the pending withdrawal request when the returned flag is set (a delegatecalled
     *      library cannot call the module's internal cancel), then runs executeDebits.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param dataProvider The module's data provider (for the price provider)
     * @param safe Address of the EtherFi Safe
     * @param tokens Addresses of the tokens to spend
     * @param amountsInUsd Amounts to spend in USD
     * @return Token amounts to spend
     * @return Portion of each amount taken from the safe's loose balance
     * @return Whether sizing dipped into balance reserved by the pending withdrawal request, in which case
     *         the caller must cancel the request before executing
     */
    function sourceDebits(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, address[] calldata tokens, uint256[] calldata amountsInUsd) external view returns (uint256[] memory, uint256[] memory, bool) {
        DebitSpendState memory s;
        s.amounts = new uint256[](tokens.length);
        s.fromLoose = new uint256[](tokens.length);
        {
            IGateway.AccountData memory account = $.gateway.getAccountData(safe);
            s.hasDebt = account.debtUsd != 0;
            s.borrowHeadroom = s.hasDebt ? account.availableBorrowsUsd : 0;
        }
        IPriceProvider priceProvider = IPriceProvider(dataProvider.getPriceProvider());

        for (uint256 i = 0; i < tokens.length; i++) {
            _sourceDebitToken($, s, priceProvider, safe, tokens[i], amountsInUsd[i], i);
        }

        return (s.amounts, s.fromLoose, s.dipped);
    }

    /**
     * @notice Executes a sized debit spend: transfers the loose portions and withdraws the supplied
     *         portions from Aave, both to the settlement dispatcher
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @param dispatcher Settlement dispatcher receiving the tokens
     * @param tokens Addresses of the tokens to spend
     * @param amounts Token amounts to spend, as sized by sourceDebits
     * @param fromLoose Portion of each amount taken from the safe's loose balance
     */
    function executeDebits(CashModuleStorageContract.CashModuleStorage storage $, address safe, address dispatcher, address[] calldata tokens, uint256[] memory amounts, uint256[] memory fromLoose) external {
        _transferLoose(safe, dispatcher, tokens, fromLoose);

        // The headroom cap in the sizing pass already bounds the supplied withdrawals; no post-withdrawal health check is needed.
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 fromSupplied = amounts[i] - fromLoose[i];
            if (fromSupplied != 0) {
                $.gateway.withdraw(safe, tokens[i], fromSupplied, dispatcher);
            }
        }
    }

    /**
     * @dev Sources one token of a debit spend: validates it, sizes the loose/supplied split against the
     *      borrowing headroom, and writes the result into s at index i. Sets s.dipped when the spend has to
     *      dip into balance reserved by the pending withdrawal request; once set, later tokens treat the
     *      reservation as void, matching the request having been cancelled at that point.
     */
    function _sourceDebitToken(CashModuleStorageContract.CashModuleStorage storage $, DebitSpendState memory s, IPriceProvider priceProvider, address safe, address token, uint256 amountInUsd, uint256 i) internal view {
        if (!$.debtManager.isBorrowToken(token)) revert UnsupportedToken();
        uint256 amount = $.debtManager.convertUsdToCollateralToken(token, amountInUsd);

        uint256 loose = IERC20(token).balanceOf(safe);
        uint256 withdrawable = DebitSourcingLib.withdrawableSupplied($.gateway, priceProvider, safe, token, s.borrowHeadroom, s.hasDebt);
        if (loose + withdrawable < amount) {
            revert InsufficientBalance();
        }

        // A pending withdrawal reserves loose balance. Prefer the unreserved portion plus the supplied
        // withdrawal so the request survives (matching CashLens); dip into the reserved portion, signalling
        // the caller to cancel the request, only when the spend cannot be funded otherwise.
        uint256 fromLoose;
        {
            uint256 pending = s.dipped ? 0 : _pendingWithdrawalAmount($, safe, token);
            uint256 unreserved = loose > pending ? loose - pending : 0;
            if (unreserved + withdrawable >= amount) {
                fromLoose = unreserved < amount ? unreserved : amount;
            } else {
                fromLoose = loose < amount ? loose : amount;
                s.dipped = true;
            }
        }

        // The supplied portion drawn for this token consumes borrowing headroom for later tokens.
        if (s.hasDebt) {
            uint256 usedUsd = DebitSourcingLib.headroomConsumed($.gateway, priceProvider, token, amount - fromLoose);
            s.borrowHeadroom = s.borrowHeadroom > usedUsd ? s.borrowHeadroom - usedUsd : 0;
        }

        s.amounts[i] = amount;
        s.fromLoose[i] = fromLoose;
    }

    /// @dev Transfers each token's loose amount from the safe to the dispatcher in one batched module call.
    function _transferLoose(address safe, address dispatcher, address[] calldata tokens, uint256[] memory amounts) internal {
        address[] memory to = new address[](tokens.length);
        bytes[] memory data = new bytes[](tokens.length);
        uint256[] memory values = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            to[i] = tokens[i];
            data[i] = abi.encodeWithSelector(IERC20.transfer.selector, dispatcher, amounts[i]);
        }
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /// @dev The amount of `token` reserved by the safe's pending withdrawal request, or 0 if none holds it.
    function _pendingWithdrawalAmount(CashModuleStorageContract.CashModuleStorage storage $, address safe, address token) internal view returns (uint256) {
        WithdrawalRequest storage req = $.safeCashConfig[safe].pendingWithdrawalRequest;
        uint256 len = req.tokens.length;
        for (uint256 i = 0; i < len;) {
            if (req.tokens[i] == token) return req.amounts[i];
            unchecked {
                ++i;
            }
        }
        return 0;
    }
}
