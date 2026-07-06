// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";
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
 *         position. It holds credit and debit spend execution, debt repayment, and the lend enable/disable
 *         lifecycle. CashModuleCore and CashModuleSetters keep only the thin entrypoints (access control,
 *         signature checks, events wiring) and delegate the work here.
 * @dev Deployed once and linked into CashModuleCore and CashModuleSetters, so this logic does not count
 *      against either implementation's EIP-170 runtime code-size limit. Every function is called via
 *      delegatecall and therefore runs in the CashModule's storage context: the caller passes its
 *      CashModuleStorage pointer and the library reads and writes the same namespaced storage the module
 *      would. One consequence of the delegatecall shape: functions that need the module's
 *      etherFiDataProvider immutable take it as a parameter. The pending-withdrawal cancel lives here
 *      (cancelOldWithdrawal) so the spend paths can cancel inline; the module's internal helper delegates
 *      to it.
 *
 *      Engine convention: legacy DebtManager code always sits inside an `if (!_usesAave(...))` block (or a
 *      legacy-named helper) that is deleted wholesale when the legacy engine is retired; the gateway path is
 *      the unguarded fall-through, already in its final shape.
 * @author ether.fi
 */
library CashLendLib {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

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
    error SettlementDispatcherNotSetForBinSponsor();

    // Threads a debit spend's cross-token state through the sizing pass. Bundled into one struct so the
    // sizing frames stay well under the legacy stack limit (the price provider is a parameter here, where in
    // the module it was a free immutable).
    struct DebitSpendState {
        uint256[] amounts; // token amount sourced per token
        uint256[] fromLoose; // portion of each amount taken from the safe's loose balance
        uint256 borrowHeadroom; // remaining USD borrowing headroom, consumed as supplied balance is drawn
        bool hasDebt; // whether the safe carries debt (the headroom cap only applies then)
        bool cancelWithdrawal; // sizing needs withdrawal-reserved balance: the spend cancels the request, and later tokens treat all loose balance as unreserved
    }

    /// @dev The canonical engine check: true routes the safe to the Aave gateway, false to the legacy DebtManager.
    ///      Every branch point in this library must read the flag through here and nothing else.
    function _usesAave(CashModuleStorageContract.CashModuleStorage storage $, address safe) private view returns (bool) {
        return $.safeCashConfig[safe].usesAave;
    }

    /**
     * @notice The settlement dispatcher receiving a bin sponsor's spends
     * @dev The module's getSettlementDispatcher delegates here; the spend paths read it directly.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param binSponsor Bin sponsor used for spending
     * @return The settlement dispatcher address
     * @custom:throws SettlementDispatcherNotSetForBinSponsor if none is configured for the bin sponsor
     */
    function settlementDispatcher(CashModuleStorageContract.CashModuleStorage storage $, BinSponsor binSponsor) public view returns (address) {
        address dispatcher;
        if (binSponsor == BinSponsor.Rain) dispatcher = $.settlementDispatcherRain;
        else if (binSponsor == BinSponsor.PIX) dispatcher = $.settlementDispatcherPix;
        else if (binSponsor == BinSponsor.CardOrder) dispatcher = $.settlementDispatcherCardOrder;
        else dispatcher = $.settlementDispatcherReap;

        if (dispatcher == address(0)) revert SettlementDispatcherNotSetForBinSponsor();
        return dispatcher;
    }

    /**
     * @notice Cancels the safe's pending withdrawal request, if any, and emits WithdrawalCancelled
     * @dev The module's internal _cancelOldWithdrawal delegates here; the spend paths in this library call
     *      it directly when a spend wins the competing claim over a reservation.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param dataProvider The module's data provider (to vet the recipient before the bridge-cancel call)
     * @param safe Address of the EtherFi Safe
     */
    function cancelOldWithdrawal(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe) public {
        SafeCashConfig storage safeCashConfig = $.safeCashConfig[safe];
        address recipient = safeCashConfig.pendingWithdrawalRequest.recipient;

        if (safeCashConfig.pendingWithdrawalRequest.tokens.length > 0) {
            if ($.whitelistedModulesCanRequestWithdraw.contains(recipient)) {
                // Only call the function if the module is whitelisted on data provider
                if (dataProvider.isWhitelistedModule(recipient)) IBridgeModule(recipient).cancelBridgeByCashModule(safe);
            }

            $.cashEventEmitter.emitWithdrawalCancelled(safe, safeCashConfig.pendingWithdrawalRequest.tokens, safeCashConfig.pendingWithdrawalRequest.amounts, recipient);
            delete safeCashConfig.pendingWithdrawalRequest;
        }
    }

    /**
     * @notice Executes a repayment on behalf of a safe, routing by engine
     * @dev The caller must have already validated the amount and cancelled any conflicting withdrawal request.
     *      A legacy safe repays the DebtManager through the safe's module execution; an Aave-gateway safe
     *      repays on Aave via the gateway (which pulls the token from the safe, repays, refunds dust, and
     *      emits Repaid).
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe The safe whose debt is repaid
     * @param token The token to repay
     * @param amount The token amount to repay
     * @param amountInUsd The USD value of the repayment (for the emitted DebtManager event)
     * @custom:throws LendGatewayNotSet if the safe uses the gateway but none is configured
     */
    function repay(CashModuleStorageContract.CashModuleStorage storage $, address safe, address token, uint256 amount, uint256 amountInUsd) external {
        if (!_usesAave($, safe)) {
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
            return;
        }

        IGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();
        // Full repays pass the max sentinel so no interest dust survives the exact-amount rounding.
        uint256 debt = gateway.debtOf(safe, token);
        uint256 repaid = gateway.repay(safe, token, amount >= debt ? type(uint256).max : amount);
        // The gateway may repay less than requested (dust refund, or the live Aave debt being smaller than
        // the quote), so report the USD value of what was actually repaid, not the requested amount.
        uint256 repaidInUsd = repaid == amount ? amountInUsd : $.debtManager.convertCollateralTokenToUsd(token, repaid);
        $.cashEventEmitter.emitRepay(safe, token, repaid, repaidInUsd);
    }

    /**
     * @notice Whether a safe has any open borrows (Aave debt via the gateway, or legacy DebtManager debt)
     * @dev Both engines are checked regardless of the safe's routing flag. In steady state debt can only
     *      live on the safe's own engine, but disabling lend must never proceed with debt anywhere: a
     *      gateway safe's disable withdraws all its Aave collateral, and an opted-out legacy safe with
     *      DebtManager debt cannot be migrated (mark-only migration reverts with LendDisabledSafeHasDebt).
     *      Checking both sides is cheap insurance instead of trusting the routing invariant.
     *
     *      Checks raw per-asset debt, not getAccountData().debtUsd: the USD aggregate floors to 6 decimals,
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
     * @dev For a gateway safe, iterates the gateway's registered assets, not DebtManager's collateral list,
     *      so a token delisted from DebtManager while still supplied on Aave stays withdrawable. A legacy
     *      safe has nothing on Aave to unwind — its opt-out is just the flag plus forced Debit mode, and it
     *      marks the safe to be left alone (funds kept loose) when the migration sweep reaches it.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function disableLend(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        if (_usesAave($, safe)) {
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
     * @notice Credit spend (single token): borrows against the safe's position, sends the borrowed token
     *         to the settlement dispatcher, and emits Spend
     * @dev A legacy safe borrows from the DebtManager, executed by the safe itself; a gateway safe borrows
     *      on Aave via the gateway. The caller has already validated the array shapes and the
     *      one-token-in-credit rule.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param dataProvider The module's data provider (to vet a legacy withdrawal cancel)
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param binSponsor Bin sponsor used for spending
     * @param tokens Address of the token to spend (single-element array)
     * @param amountsInUsd Amount to spend in USD (single-element array)
     * @param totalSpendingInUsd Total spend in USD, for the emitted event
     */
    function spendCredit(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, bytes32 txId, BinSponsor binSponsor, address[] calldata tokens, uint256[] calldata amountsInUsd, uint256 totalSpendingInUsd) external {
        // Defense-in-depth: a safe that opted out of lend is forced to Debit and blocked from re-entering
        // Credit, so credit spending must never reach a lend-disabled safe.
        if ($.safeCashConfig[safe].lendDisabled) revert LendDisabled();
        if (!$.debtManager.isBorrowToken(tokens[0])) revert UnsupportedToken();
        uint256 amount = $.debtManager.convertUsdToCollateralToken(tokens[0], amountsInUsd[0]);
        if (amount == 0) revert AmountZero();

        if (!_usesAave($, safe)) {
            _spendLegacyCredit($, dataProvider, safe, binSponsor, tokens[0], amount);
        } else {
            _borrowOnGateway($, safe, binSponsor, tokens[0], amount);
        }

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, tokens, amounts, amountsInUsd, totalSpendingInUsd, Mode.Credit);
    }

    /// @dev Gateway credit spend: the safe's position lives on Aave, so borrow there via the gateway (the
    ///      CashModule is always a gateway driver) and send the borrowed token straight to the settlement
    ///      dispatcher. The legacy DebtManager.borrow path reverts for a migrated safe, and CashLens sizes
    ///      credit against the same engine flag, so routing here keeps the on-chain spend consistent with
    ///      the precheck. Aave enforces the borrowing-power/health check on the borrow itself.
    function _borrowOnGateway(CashModuleStorageContract.CashModuleStorage storage $, address safe, BinSponsor binSponsor, address token, uint256 amount) private {
        IGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();
        gateway.borrow(safe, token, amount, settlementDispatcher($, binSponsor));
    }

    /// @dev Legacy credit spend: a DebtManager borrow executed by the safe itself. A blocked borrow means
    ///      the pending withdrawal request holds the balance the borrow needs: the spend wins the competing
    ///      claim (the debit path's rule), so cancel the request and retry.
    function _spendLegacyCredit(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, BinSponsor binSponsor, address token, uint256 amount) private {
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        to[0] = address($.debtManager);
        data[0] = abi.encodeWithSelector(IDebtManager.borrow.selector, binSponsor, token, amount);

        try IEtherFiSafe(safe).execTransactionFromModule(to, values, data) { }
        catch {
            cancelOldWithdrawal($, dataProvider, safe);
            IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        }
    }

    /**
     * @notice Debit spend (multiple tokens): sizes each token against the safe's balances, executes the
     *         transfers to the settlement dispatcher, and emits Spend
     * @dev A gateway safe spends its loose balance first, then its Aave-supplied balance covers any
     *      shortfall; a legacy safe spends its loose balance only. When sizing needs balance reserved by
     *      the pending withdrawal request, the spend wins the competing claim and the request is cancelled
     *      before any transfer executes.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param dataProvider The module's data provider (for the price provider and withdrawal cancels)
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param binSponsor Bin sponsor used for spending
     * @param tokens Addresses of the tokens to spend
     * @param amountsInUsd Amounts to spend in USD
     * @param totalSpendingInUsd Total spend in USD, for the emitted event
     */
    function spendDebit(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, bytes32 txId, BinSponsor binSponsor, address[] calldata tokens, uint256[] calldata amountsInUsd, uint256 totalSpendingInUsd) external {
        if (!_usesAave($, safe)) {
            _spendLegacyDebit($, dataProvider, safe, txId, binSponsor, tokens, amountsInUsd, totalSpendingInUsd);
            return;
        }

        DebitSpendState memory s = _sourceDebits($, dataProvider, safe, tokens, amountsInUsd);
        if (s.cancelWithdrawal) cancelOldWithdrawal($, dataProvider, safe);
        _executeDebits($, safe, settlementDispatcher($, binSponsor), tokens, s.amounts, s.fromLoose);
        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, tokens, s.amounts, amountsInUsd, totalSpendingInUsd, Mode.Debit);
    }

    /// @dev Legacy debit spend: every token comes from the loose balance (so _executeDebits performs pure
    ///      transfers), reproducing the pre-gateway behavior exactly. Loose tokens are the legacy engine's
    ///      collateral, so if the position is unhealthy after the spend, the pending withdrawal request
    ///      loses the competing claim: cancel it and check again.
    function _spendLegacyDebit(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, bytes32 txId, BinSponsor binSponsor, address[] calldata tokens, uint256[] calldata amountsInUsd, uint256 totalSpendingInUsd) private {
        DebitSpendState memory s = _sourceLegacyDebits($, safe, tokens, amountsInUsd);
        if (s.cancelWithdrawal) cancelOldWithdrawal($, dataProvider, safe);
        _executeDebits($, safe, settlementDispatcher($, binSponsor), tokens, s.amounts, s.fromLoose);
        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, tokens, s.amounts, amountsInUsd, totalSpendingInUsd, Mode.Debit);

        try $.debtManager.ensureHealth(safe) { }
        catch {
            cancelOldWithdrawal($, dataProvider, safe);
            $.debtManager.ensureHealth(safe);
        }
    }

    /**
     * @dev Sizes a gateway debit spend across tokens: the safe's loose balance is spent first, then the
     *      Aave-supplied balance covers any shortfall. Per token, _sourceDebitToken sizes the loose/supplied
     *      split and threads the borrowing headroom across tokens, so a debit cannot push a debt-carrying
     *      safe past its LTV max borrow. Pure sizing: the returned flag tells the caller to cancel the
     *      pending withdrawal request before executing.
     */
    function _sourceDebits(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, address[] calldata tokens, uint256[] calldata amountsInUsd) private view returns (DebitSpendState memory) {
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

        return s;
    }

    /**
     * @notice Transfers liquidated collateral from the safe to the liquidator, skipping zero amounts
     * @dev The execution half of CashModule.postLiquidate (the DebtManager-only auth stays in the module);
     *      lives here purely for the module's code-size budget
     * @param safe Address of the EtherFi Safe being liquidated
     * @param liquidator Address receiving the liquidated tokens
     * @param tokensToSend Token amounts to send, as computed by the DebtManager
     */
    function postLiquidateTransfers(address safe, address liquidator, IDebtManager.LiquidationTokenData[] memory tokensToSend) external {
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
     * @dev Sizes a legacy debit spend: every token is spent from the safe's loose balance, sized exactly as
     *      the pre-gateway DebtManager-era module did. Pure sizing: the returned flag is set when a token's
     *      spend plus its withdrawal reservation exceeds the loose balance (the spend wins the competing
     *      claim); once set, later tokens treat the reservation as already void.
     */
    function _sourceLegacyDebits(CashModuleStorageContract.CashModuleStorage storage $, address safe, address[] calldata tokens, uint256[] calldata amountsInUsd) private view returns (DebitSpendState memory) {
        DebitSpendState memory s;
        s.amounts = new uint256[](tokens.length);
        // Every token comes from the loose balance, so the execution pass performs pure transfers.
        s.fromLoose = s.amounts;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (!$.debtManager.isBorrowToken(tokens[i])) revert UnsupportedToken();
            s.amounts[i] = $.debtManager.convertUsdToCollateralToken(tokens[i], amountsInUsd[i]);

            uint256 balance = IERC20(tokens[i]).balanceOf(safe);
            if (balance < s.amounts[i]) revert InsufficientBalance();

            if (!s.cancelWithdrawal && s.amounts[i] + _pendingWithdrawalAmount($, safe, tokens[i]) > balance) {
                s.cancelWithdrawal = true;
            }
        }

        return s;
    }

    /**
     * @dev Executes a sized debit spend: transfers the loose portions and withdraws the supplied portions
     *      from Aave, both to the settlement dispatcher
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @param dispatcher Settlement dispatcher receiving the tokens
     * @param tokens Addresses of the tokens to spend
     * @param amounts Token amounts to spend, as sized by the sourcing pass
     * @param fromLoose Portion of each amount taken from the safe's loose balance
     */
    function _executeDebits(CashModuleStorageContract.CashModuleStorage storage $, address safe, address dispatcher, address[] calldata tokens, uint256[] memory amounts, uint256[] memory fromLoose) private {
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
     *      borrowing headroom, and writes the result into s at index i. Sets s.cancelWithdrawal when the
     *      spend needs balance reserved by the pending withdrawal request; once set, later tokens treat the
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
        // withdrawal so the request survives (matching CashLens). Only when that cannot fund the spend is
        // the request condemned: the caller cancels it, so the reservation is lifted here and for every
        // later token.
        uint256 fromLoose;
        {
            uint256 pending = s.cancelWithdrawal ? 0 : _pendingWithdrawalAmount($, safe, token);
            uint256 spendableLoose = loose > pending ? loose - pending : 0;
            if (spendableLoose + withdrawable < amount) {
                s.cancelWithdrawal = true;
                spendableLoose = loose;
            }
            fromLoose = spendableLoose < amount ? spendableLoose : amount;
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
