// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";
import { BinSponsor, Mode, SafeCashConfig, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ILendGateway } from "../../interfaces/ILendGateway.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../libraries/CashVerificationLib.sol";
import { LendSourcingLib } from "../../libraries/LendSourcingLib.sol";
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashLendLib
 * @notice The CashModule's lend logic: every module operation that touches the Aave gateway or the safe's
 *         position. It holds credit and debit spend execution, debt repayment, and the lend opt-in/opt-out
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
 *      Engine convention: legacy DebtManager code always sits inside an `if (!_usesLendGateway(...))` block (or a
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
    error LendAlreadyOptedOut();
    error HasOpenBorrows();
    error LendNotOptedOut();
    error LendOptedOut();
    error AmountZero();
    error SettlementDispatcherNotSetForBinSponsor();
    error OnlyLendGatewaySafe();
    error OnlyBorrowToken();

    /// @dev Pad on resupply sizing so Aave share rounding cannot leave the headroom short; excess supply is harmless
    uint256 internal constant RESUPPLY_BUFFER_BPS = 10;

    // Threads a debit spend's cross-token state through the sizing pass. Bundled into one struct so the
    // sizing frames stay well under the legacy stack limit (the price provider is a parameter here, where in
    // the module it was a free immutable).
    struct DebitSpendState {
        uint256[] amounts; // token amount sourced per token
        uint256[] fromLoose; // portion of each amount taken from the safe's loose balance
        uint256 withdrawHeadroom; // remaining Aave-priced collateral headroom (weighted Value), consumed as supplied balance is drawn
        bool hasDebt; // whether the safe carries debt (the headroom cap only applies then)
        bool cancelWithdrawal; // sizing needs withdrawal-reserved balance: the spend cancels the request, and later tokens treat all loose balance as unreserved
    }

    /// @dev The canonical engine check: true routes the safe to the Aave gateway, false to the legacy DebtManager.
    ///      Every branch point in this library must read the flag through here and nothing else.
    function _usesLendGateway(CashModuleStorageContract.CashModuleStorage storage $, address safe) private view returns (bool) {
        return $.safeCashConfig[safe].usesLendGateway;
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
     * @dev Each engine converts the USD quote itself: a legacy safe through the DebtManager, a gateway safe
     *      through the PriceProvider, so the gateway path never touches the DebtManager. A legacy safe
     *      repays the DebtManager from its loose balance through the safe's module execution, cancelling a
     *      conflicting withdrawal request first. A gateway safe repays on Aave via the gateway, sourcing
     *      like a debit spend: unreserved loose balance first, then the safe's Aave-supplied balance of the
     *      same token (Aave v4 has no repay-with-aTokens, so the shortfall is withdrawn to the safe and
     *      repaid), and only as a last resort the withdrawal-reserved loose balance, cancelling the request
     *      (the spend paths' rule). The loose leg repays before the withdraw so the freed headroom sizes
     *      the supplied leg.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param dataProvider The module's data provider (for the price provider and withdrawal cancels)
     * @param safe The safe whose debt is repaid
     * @param token The token to repay
     * @param amountInUsd The USD value to repay, capped at the open debt
     * @custom:throws OnlyBorrowToken if the token cannot carry debt on the safe's engine
     * @custom:throws LendGatewayNotSet if the safe uses the gateway but none is configured
     * @custom:throws AmountZero if the quote converts to zero or the safe has no debt in the token
     * @custom:throws InsufficientBalance if the safe cannot source the capped amount (the supplied leg is
     *                bounded by borrowing headroom; a max-leveraged position unloops over multiple repays)
     */
    function repay(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, address token, uint256 amountInUsd) external {
        uint256 amount;
        if (!_usesLendGateway($, safe)) {
            if (!$.debtManager.isBorrowToken(token)) revert OnlyBorrowToken();
            amount = $.debtManager.convertUsdToCollateralToken(token, amountInUsd);
            if (amount == 0) revert AmountZero();
            _cancelCompetingWithdrawal($, dataProvider, safe, token, amount);

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

        ILendGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();
        // Registered, not borrowable: debt can sit on a reserve that stopped being borrowable (flag off,
        // or frozen), and Aave allows repaying it. Only new debt takes the borrowable gate.
        if (!gateway.isRegistered(token)) revert OnlyBorrowToken();
        IPriceProvider priceProvider = IPriceProvider(dataProvider.getPriceProvider());
        amount = LendSourcingLib.fromUsd(priceProvider, token, amountInUsd);
        uint256 debt = gateway.debtOf(safe, token);
        if (amount > debt) {
            // Re-derive the USD value so the capped repay does not report the requested amount
            amount = debt;
            amountInUsd = LendSourcingLib.toUsd(priceProvider, token, amount);
        }
        if (amount == 0) revert AmountZero();

        (uint256 fromLoose, uint256 fromSupplied, bool cancelWithdrawal) = _sourceRepay($, gateway, safe, token, amount);
        if (cancelWithdrawal) cancelOldWithdrawal($, dataProvider, safe);

        // A full repay passes the max sentinel on its last leg so no interest dust survives the
        // exact-amount rounding.
        uint256 repaid;
        if (fromSupplied == 0) {
            // Loose covers the whole amount
            repaid = gateway.repay(safe, token, amount == debt ? type(uint256).max : amount);
        } else {
            if (fromLoose != 0) repaid = gateway.repay(safe, token, fromLoose);
            gateway.withdraw(safe, token, fromSupplied, safe);
            repaid += gateway.repay(safe, token, amount == debt ? type(uint256).max : fromSupplied);
        }

        // The gateway may repay less than requested (dust refund, or the live Aave debt being smaller than
        // the quote), so report the USD value of what was actually repaid, not the requested amount.
        uint256 repaidInUsd = repaid == amount ? amountInUsd : LendSourcingLib.toUsd(priceProvider, token, repaid);
        $.cashEventEmitter.emitRepay(safe, token, repaid, repaidInUsd);
    }

    /**
     * @dev Cancels the safe's pending withdrawal request when it competes with a legacy repay of `token`:
     *      if the quoted amount plus the token's reserved leg exceeds the loose balance, the repay outranks
     *      the reservation. Conservative on purpose: the quote may exceed the live debt, so a repay quoted
     *      above the debt can cancel a request the real, smaller pull would have left intact.
     * @custom:throws InsufficientBalance if `amount` exceeds the safe's loose balance of `token`
     */
    function _cancelCompetingWithdrawal(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, address token, uint256 amount) private {
        uint256 balance = IERC20(token).balanceOf(safe);
        if (amount > balance) revert InsufficientBalance();
        if (amount + _pendingWithdrawalAmount($, safe, token) > balance) cancelOldWithdrawal($, dataProvider, safe);
    }

    /**
     * @dev Sizes a gateway repay across the safe's pots: unreserved loose balance, then Aave-supplied
     *      balance capped by borrowing headroom (credited with the headroom the loose leg's repay frees),
     *      then withdrawal-reserved loose balance. Returns the loose leg (reserved portion included), the
     *      supplied leg, and whether the pending withdrawal request must be cancelled.
     * @custom:throws InsufficientBalance if the three pots cannot cover `amount`
     */
    function _sourceRepay(CashModuleStorageContract.CashModuleStorage storage $, ILendGateway gateway, address safe, address token, uint256 amount) private view returns (uint256, uint256, bool) {
        // Split the safe's loose balance into what a pending withdrawal has reserved and what is free
        uint256 loose = IERC20(token).balanceOf(safe);
        uint256 reserved = _pendingWithdrawalAmount($, safe, token);
        if (reserved > loose) reserved = loose;
        uint256 unreserved = loose - reserved;

        // Pot 1: unreserved loose balance
        uint256 fromLoose = amount < unreserved ? amount : unreserved;
        uint256 shortfall = amount - fromLoose;
        if (shortfall == 0) return (fromLoose, 0, false);

        // Pot 2: the safe's Aave-supplied balance, capped by borrowing headroom. The loose leg repays
        // before the withdraw executes, so the sizing credits the headroom that repay frees.
        uint256 fromSupplied = LendSourcingLib.repayWithdrawable(gateway, safe, token, fromLoose);
        if (fromSupplied > shortfall) fromSupplied = shortfall;
        shortfall -= fromSupplied;
        if (shortfall == 0) return (fromLoose, fromSupplied, false);

        // Pot 3: the reserved loose balance. The repay wins the competing claim, so the caller cancels
        // the withdrawal request. Nothing left after that means the repay cannot be funded.
        if (shortfall > reserved) revert InsufficientBalance();
        return (fromLoose + shortfall, fromSupplied, true);
    }

    /**
     * @notice Pulls each requested token's shortfall out of the lend market into the safe, so a
     *         withdrawal request is funded even while the balance sits supplied (the pull-first step
     *         of the withdrawal flow)
     * @dev A legacy safe skips the pull: its balances never sit in the lend market. The caller has
     *      already cancelled any pending withdrawal, so the whole loose balance counts. Per token, the
     *      pull is capped at the safe's supplied balance and the caller's balance check still rejects a
     *      request the two pots cannot fund; Aave enforces the position's health on the pull itself, so
     *      a withdrawal that would leave the safe unhealthy reverts here. The pulled funds sit loose
     *      through the withdrawal delay; the auto-supply sweep nets out the pending reservation, so it
     *      never sweeps them back. A cancel leaves them loose on purpose (re-supplying there would let
     *      a paused reserve block the cancel); the next sweep restores them as collateral.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @param tokens Tokens in the withdrawal request
     * @param amounts Requested token amounts
     * @custom:throws LendGatewayNotSet if the safe uses the gateway but none is configured
     */
    function sourceWithdrawal(CashModuleStorageContract.CashModuleStorage storage $, address safe, address[] memory tokens, uint256[] memory amounts) external {
        if (!_usesLendGateway($, safe)) return;
        ILendGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();

        bool pulled;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!gateway.isRegistered(tokens[i])) continue;
            uint256 loose = IERC20(tokens[i]).balanceOf(safe);
            if (amounts[i] <= loose) continue;
            uint256 shortfall = amounts[i] - loose;
            uint256 supplied = gateway.suppliedOf(safe, tokens[i]);
            if (supplied == 0) continue;
            gateway.withdraw(safe, tokens[i], shortfall > supplied ? supplied : shortfall, safe);
            pulled = true;
        }
        // A withdrawal is a user extraction, so pulling from Aave takes the health-factor floor; a
        // loose-balance-only withdrawal never touches the position and is exempt (as are card spends)
        if (pulled) gateway.ensureMinHealthFactor(safe);
    }

    /**
     * @notice Supplies a safe's loose balances into the lend market and flags them as collateral (the
     *         auto-supply sweep)
     * @dev Per token: supplies the loose balance net of the pending-withdrawal reservation, so a queued
     *      withdrawal is never swept back into Aave. Zero and unregistered tokens are skipped, and the
     *      supply is best-effort (a reserve that rejects it, e.g. frozen/paused/at cap, leaves the funds
     *      loose for the next sweep), so a keeper batch never bricks. An opted-out safe is a no-op, since
     *      the keeper legitimately races an opt-out; a legacy safe reverts, since routing one here is a
     *      keeper bug.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @param tokens Tokens to sweep
     * @custom:throws OnlyLendGatewaySafe if the safe runs on the legacy DebtManager engine
     * @custom:throws LendGatewayNotSet if no gateway is configured
     */
    function supplyToLend(CashModuleStorageContract.CashModuleStorage storage $, address safe, address[] calldata tokens) external {
        ILendGateway gateway = _requireGateway($, safe);
        processLendOptOutIfReady($, safe);
        if (isLendOptedOut($, safe)) return;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (!gateway.isRegistered(tokens[i])) continue;
            uint256 amount = IERC20(tokens[i]).balanceOf(safe);
            uint256 pending = _pendingWithdrawalAmount($, safe, tokens[i]);
            amount = amount > pending ? amount - pending : 0;
            if (amount == 0) continue;
            _supplyAsCollateral($, gateway, safe, tokens[i], amount);
        }
    }

    /**
     * @notice Borrows `token` against the safe's lend-market position; the proceeds land in the safe and
     *         are supplied back as collateral, best-effort (a borrow-page borrow with instant auto-supply)
     * @dev Owner-quorum signed: the signatures bind the token and USD amount, so neither a compromised backend
     *      nor a single compromised admin can lever a safe up; the caller has already resolved and consumed the
     *      nonce. The proceeds are supplied back as collateral best-effort: if that reserve rejects the supply
     *      (e.g. at its supply cap), the proceeds stay loose and the next sweep restores them, rather than
     *      failing the borrow the owners signed for. Aave enforces the health check on the borrow itself, and
     *      the gateway rejects a borrow for an opted-out safe; the lendOptedOut check here is defense-in-depth,
     *      mirroring spendCredit.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param dataProvider The module's data provider (for the price provider)
     * @param safe Address of the EtherFi Safe
     * @param token The token to borrow
     * @param amountInUsd The USD value of the borrow (bound by the signatures and emitted in the event)
     * @param nonce The safe's next nonce (resolved and consumed by the caller)
     * @param signers The owners who authorized the borrow
     * @param signatures The signers' signatures over the intent
     * @custom:throws InvalidSignatures if the signatures do not meet the owner quorum
     * @custom:throws OnlyLendGatewaySafe if the safe runs on the legacy DebtManager engine
     * @custom:throws LendGatewayNotSet if no gateway is configured
     * @custom:throws LendOptedOut if the safe has opted out of the lend market
     * @custom:throws OnlyBorrowToken if token is not borrowable on the gateway
     * @custom:throws AmountZero if the converted amount is zero
     */
    function borrow(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, address token, uint256 amountInUsd, uint256 nonce, address[] calldata signers, bytes[] calldata signatures) external {
        CashVerificationLib.verifyBorrowSig(safe, nonce, token, amountInUsd, signers, signatures);
        ILendGateway gateway = _requireGateway($, safe);
        if (isLendOptedOut($, safe)) revert LendOptedOut();

        if (!gateway.isBorrowable(token)) revert OnlyBorrowToken();
        uint256 amount = LendSourcingLib.fromUsd(IPriceProvider(dataProvider.getPriceProvider()), token, amountInUsd);
        if (amount == 0) revert AmountZero();

        gateway.borrow(safe, token, amount, safe);
        _supplyAsCollateral($, gateway, safe, token, amount);
        // The borrow page takes the health-factor floor (post-resupply end state); card spends are exempt
        gateway.ensureMinHealthFactor(safe);
        $.cashEventEmitter.emitLendBorrowed(safe, token, amount, amountInUsd);
    }

    /// @dev The lend ops require the safe on the gateway engine and a configured gateway
    function _requireGateway(CashModuleStorageContract.CashModuleStorage storage $, address safe) private view returns (ILendGateway) {
        if (!_usesLendGateway($, safe)) revert OnlyLendGatewaySafe();
        ILendGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();
        return gateway;
    }

    /// @dev Best-effort supply of `amount` of `token` into the lend market as collateral. A supply the
    ///      reserve rejects (frozen, paused, at its supply cap, or the Hub spoke halted) is swallowed so the
    ///      funds stay loose for the next sweep. Used by the sweep and the borrow auto-supply, where leaving
    ///      the funds loose is fine; callers that must not proceed without the supply do not use this.
    function _supplyAsCollateral(CashModuleStorageContract.CashModuleStorage storage $, ILendGateway gateway, address safe, address token, uint256 amount) private {
        try gateway.supply(safe, token, amount) {
            gateway.setUsingAsCollateral(safe, token, true);
            $.cashEventEmitter.emitLendSupplied(safe, token, amount);
        } catch { }
    }

    /**
     * @notice Whether a safe has any open borrows (Aave debt via the gateway, or legacy DebtManager debt)
     * @dev Both engines are checked regardless of the safe's routing flag. In steady state debt can only
     *      live on the safe's own engine, but disabling lend must never proceed with debt anywhere: a
     *      gateway safe's disable withdraws all its Aave collateral, and an opted-out legacy safe with
     *      DebtManager debt cannot be migrated (mark-only migration reverts with LendOptedOutSafeHasDebt).
     *      Checking both sides is cheap insurance instead of trusting the routing invariant.
     *
     *      Checks raw per-asset debt, not getAccountData().debtUsd: the USD aggregate floors to 6 decimals,
     *      so sub-$0.000001 dust reads as zero here and then reverts deep in Aave when executeLendOptOut tries to
     *      withdraw all collateral.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function hasOpenBorrows(CashModuleStorageContract.CashModuleStorage storage $, address safe) public view returns (bool) {
        ILendGateway gateway = $.gateway;
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
     * @notice Whether the safe is effectively opted out of lend: either the opt-out has been processed,
     *         or a pending request's finalize time has passed (mirroring how getMode honors a matured
     *         incoming mode before _setCurrentMode has applied it)
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @return True if the safe is opted out or a matured opt-out request awaits processing
     */
    function isLendOptedOut(CashModuleStorageContract.CashModuleStorage storage $, address safe) public view returns (bool) {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        return $$.lendOptedOut || ($$.lendOptOutFinalizeTime != 0 && block.timestamp > $$.lendOptOutFinalizeTime);
    }

    /**
     * @notice Lazily executes a matured lend opt-out on the mutating paths, so a user never has to wait
     *         for the permissionless processLendOptOut call (the opt-out twin of _setCurrentMode)
     * @dev No-op when nothing is pending or the delay hasn't elapsed. Also a no-op — never a revert — when
     *      open borrows block the unwind (all collateral cannot be withdrawn under debt): the effective
     *      views already report the safe as opted out meanwhile, and the next touch after the debt clears
     *      (e.g. repay) completes the opt-out.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function processLendOptOutIfReady(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        // Strictly after the finalize time, matching isLendOptedOut and the incoming-mode rail, so reads
        // and lazy processing flip in the same second
        if ($$.lendOptOutFinalizeTime == 0 || block.timestamp <= $$.lendOptOutFinalizeTime) return;
        if (hasOpenBorrows($, safe)) return;
        // Best-effort unwind: a temporarily failing withdraw (paused gateway or reserve) must not revert
        // the unrelated action that triggered the lazy processing — the opt-out stays pending (the
        // effective views already report it) and the next touch retries. The opt-out is only marked
        // processed once everything is actually withdrawn.
        if (!_unwindLendCollateral($, safe, true)) return;
        _finalizeLendOptOut($, safe);
    }

    /**
     * @notice Records a lend opt-out request for a safe (executable after modeDelay)
     * @dev Reverts if the safe already opted out or a request is pending or the safe has open borrows. Executes immediately
     *      if the delay is zero.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function requestLendOptOut(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];

        if ($$.lendOptedOut || $$.lendOptOutFinalizeTime != 0) revert LendAlreadyOptedOut();
        if (hasOpenBorrows($, safe)) revert HasOpenBorrows();

        uint96 finalizeTime = uint96(block.timestamp) + $.modeDelay;
        $$.lendOptOutFinalizeTime = finalizeTime;

        if ($$.incomingModeStartTime != 0 && block.timestamp > $$.incomingModeStartTime) $$.mode = $$.incomingMode;
        delete $$.incomingMode;
        delete $$.incomingModeStartTime;
        if ($$.mode == Mode.Credit) {
            $$.incomingMode = Mode.Debit;
            $$.incomingModeStartTime = finalizeTime;
            $.cashEventEmitter.emitSetMode(safe, Mode.Credit, Mode.Debit, finalizeTime);
        }

        $.cashEventEmitter.emitLendOptOutRequested(safe, finalizeTime);

        if ($.modeDelay == 0) executeLendOptOut($, safe);
    }

    /**
     * @notice Executes the lend opt-out: withdraws ALL of the safe's Aave collateral back to the safe, marks
     *         the safe opted out, and forces it into Debit mode
     * @dev For a gateway safe, iterates the gateway's registered assets, not DebtManager's collateral list,
     *      so a token delisted from DebtManager while still supplied on Aave stays withdrawable. A legacy
     *      safe has nothing on Aave to unwind — its opt-out is just the flag plus forced Debit mode, and it
     *      marks the safe to be left alone (funds kept loose) when the migration sweep reaches it.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function executeLendOptOut(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        _unwindLendCollateral($, safe, false);
        _finalizeLendOptOut($, safe);
    }

    /**
     * @notice Withdraws ALL of the safe's Aave collateral back to the safe
     * @dev For a gateway safe, iterates the gateway's registered assets, not DebtManager's collateral list,
     *      so a token delisted from DebtManager while still supplied on Aave stays withdrawable. A legacy
     *      safe has nothing on Aave to unwind. In best-effort mode a failing withdraw (paused gateway or
     *      reserve) is swallowed and reported instead of reverting, and the other tokens still unwind, so
     *      the lazy paths never block an unrelated action; the strict mode (explicit processLendOptOut,
     *      zero-delay requests) lets the error surface to the caller.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     * @param bestEffort True to swallow individual withdraw failures instead of reverting
     * @return fullyUnwound True when nothing is left supplied on Aave
     */
    function _unwindLendCollateral(CashModuleStorageContract.CashModuleStorage storage $, address safe, bool bestEffort) private returns (bool fullyUnwound) {
        fullyUnwound = true;
        if (!_usesLendGateway($, safe)) return fullyUnwound;

        ILendGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();

        address[] memory collateralTokens = gateway.registeredAssets();
        uint256 len = collateralTokens.length;
        for (uint256 i = 0; i < len;) {
            uint256 supplied = gateway.suppliedOf(safe, collateralTokens[i]);
            if (supplied != 0) {
                if (bestEffort) {
                    try gateway.withdraw(safe, collateralTokens[i], supplied, safe) { }
                    catch {
                        fullyUnwound = false;
                    }
                } else {
                    gateway.withdraw(safe, collateralTokens[i], supplied, safe);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Marks the opt-out processed: sets the flag, clears the pending request, and forces Debit
     * @dev Only called once the collateral is fully unwound (or there was none). Credit needs lend
     *      collateral, so the mode is forced to Debit and any pending mode change is dropped.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function _finalizeLendOptOut(CashModuleStorageContract.CashModuleStorage storage $, address safe) private {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        $$.lendOptedOut = true;
        $$.lendOptOutFinalizeTime = 0;
        // Credit needs lend collateral, so force Debit and drop any pending mode change
        $$.mode = Mode.Debit;
        delete $$.incomingMode;
        delete $$.incomingModeStartTime;

        $.cashEventEmitter.emitLendOptOutExecuted(safe);
    }

    /**
     * @notice Opts a safe back into lend and cancels any pending opt-out request
     * @dev Instant, since opting back into earning is not risk-increasing. Reverts if lend is already
     *      enabled and no opt-out is pending.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param safe Address of the EtherFi Safe
     */
    function optInToLend(CashModuleStorageContract.CashModuleStorage storage $, address safe) public {
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        if (!$$.lendOptedOut && $$.lendOptOutFinalizeTime == 0) revert LendNotOptedOut();

        if ($$.lendOptOutFinalizeTime != 0) {
            if ($$.incomingModeStartTime != 0 && block.timestamp > $$.incomingModeStartTime) $$.mode = $$.incomingMode;
            delete $$.incomingMode;
            delete $$.incomingModeStartTime;
        }

        $$.lendOptedOut = false;
        $$.lendOptOutFinalizeTime = 0;
        $.cashEventEmitter.emitLendOptedIn(safe);
    }

    /**
     * @notice Credit spend (single token): borrows against the safe's position, sends the borrowed token
     *         to the settlement dispatcher, and emits Spend
     * @dev A legacy safe borrows from the DebtManager, executed by the safe itself; a gateway safe borrows
     *      on Aave via the gateway, first resupplying loose collateral if the position's borrowing power no
     *      longer covers the spend. The caller has already validated the array shapes and the
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
        // Credit, so credit spending must never reach an opted-out safe. Effective check: a matured
        // opt-out blocked from lazy processing by open borrows must still stop borrowing more.
        if (isLendOptedOut($, safe)) revert LendOptedOut();

        uint256 amount;
        if (!_usesLendGateway($, safe)) {
            if (!$.debtManager.isBorrowToken(tokens[0])) revert UnsupportedToken();
            amount = $.debtManager.convertUsdToCollateralToken(tokens[0], amountsInUsd[0]);
            if (amount == 0) revert AmountZero();
            _spendLegacyCredit($, dataProvider, safe, binSponsor, tokens[0], amount);
        } else {
            amount = _spendGatewayCredit($, dataProvider, safe, binSponsor, tokens[0], amountsInUsd[0]);
        }

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        $.cashEventEmitter.emitSpend(safe, txId, binSponsor, tokens, amounts, amountsInUsd, totalSpendingInUsd, Mode.Credit);
    }

    /**
     * @dev Credit spend on the Aave engine: borrow the settlement token via the gateway and send it straight
     *      to the settlement dispatcher. This path never touches the DebtManager. Aave enforces the health
     *      check on the borrow itself; the configured floor is not enforced here, so an already-authorized
     *      spend stays executable down to Aave's 1.00 boundary.
     * @param $ The CashModule storage pointer
     * @param dataProvider The EtherFiDataProvider
     * @param safe The safe whose position takes on the debt
     * @param binSponsor The bin sponsor selecting the settlement dispatcher
     * @param token The settlement token to borrow
     * @param amountInUsd The authorized payment amount, in 6-decimal payment USD
     * @return The borrowed token amount sent to the settlement dispatcher
     */
    function _spendGatewayCredit(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, address safe, BinSponsor binSponsor, address token, uint256 amountInUsd) private returns (uint256) {
        ILendGateway gateway = $.gateway;
        if (address(gateway) == address(0)) revert LendGatewayNotSet();
        // The drawn token settles the card, so it must be a card-settleable spend asset AND borrowable on Aave
        if (!gateway.isBorrowable(token) || !gateway.isSpendAsset(token)) revert UnsupportedToken();
        // Round the token amount up so it always covers the authorized payment USD
        uint256 amount = LendSourcingLib.fromUsdUp(IPriceProvider(dataProvider.getPriceProvider()), token, amountInUsd);
        if (amount == 0) revert AmountZero();
        _resupplyForCreditShortfall($, dataProvider, gateway, safe, token, amount);
        gateway.borrow(safe, token, amount, settlementDispatcher($, binSponsor));
        return amount;
    }

    /**
     * @dev Resupplies loose collateral for the part of a pending borrow of `amount` that Aave's raw (1.00)
     *      capacity cannot cover. Gating on the raw capacity, not the configured floor, is what lets an
     *      authorized spend execute in the band between the floor and 1.00 without touching the safe's funds.
     * @param $ The CashModule storage pointer
     * @param dataProvider The EtherFiDataProvider
     * @param gateway The LendGateway serving the safe
     * @param safe The safe whose position takes on the debt
     * @param token The settlement token being borrowed
     * @param amount The token amount the pending borrow will draw
     */
    function _resupplyForCreditShortfall(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, ILendGateway gateway, address safe, address token, uint256 amount) private {
        uint256 rawCapacity = gateway.rawBorrowCapacity(safe, token);
        if (rawCapacity >= amount) return;
        // Aave-priced: the collateral the shortfall's borrow requires at Aave's own 1.00 bound
        uint256 shortfallValue = gateway.borrowValue(token, amount - rawCapacity);
        _resupplyCollateral($, dataProvider, gateway, safe, shortfallValue);
    }

    /**
     * @dev Supplies loose collateral to cover the pre-measured shortfall. The first sizing pass uses only
     *      balance not reserved by the pending withdrawal request; the reserved remainder is taken only when
     *      the spend cannot be funded otherwise, and then the request is cancelled before any supply executes
     *      (the debit path's rule). If loose collateral cannot fully cover, it supplies what fits and the
     *      caller's borrow reverts the whole spend. CashLens never counts this capacity, so canSpend does not
     *      advertise it as headroom.
     * @param $ The CashModule storage pointer
     * @param dataProvider The EtherFiDataProvider
     * @param gateway The LendGateway serving the safe
     * @param safe The safe whose position is topped up with collateral
     * @param shortfallValue The shortfall to cover, in weighted collateral value, measured against raw capacity
     */
    function _resupplyCollateral(CashModuleStorageContract.CashModuleStorage storage $, IEtherFiDataProvider dataProvider, ILendGateway gateway, address safe, uint256 shortfallValue) private {
        address[] memory tokens = gateway.registeredAssets();
        uint256[] memory supplyAmounts = new uint256[](tokens.length);

        // Pad once at entry so Aave's supply/draw share rounding cannot leave the headroom short; the
        // ceil keeps a dust shortfall from vanishing. Excess supply is harmless.
        shortfallValue = (shortfallValue * (10_000 + RESUPPLY_BUFFER_BPS) + 9999) / 10_000;

        shortfallValue = _sizeResupply($, gateway, safe, tokens, supplyAmounts, shortfallValue, false);
        if (shortfallValue != 0) {
            _sizeResupply($, gateway, safe, tokens, supplyAmounts, shortfallValue, true);
            cancelOldWithdrawal($, dataProvider, safe);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            if (supplyAmounts[i] != 0) {
                gateway.supply(safe, tokens[i], supplyAmounts[i]);
                gateway.setUsingAsCollateral(safe, tokens[i], true);
                $.cashEventEmitter.emitCollateralResupplied(safe, tokens[i], supplyAmounts[i]);
            }
        }
    }

    /**
     * @dev One resupply sizing pass over the gateway's registered assets, accumulating into `supplyAmounts`.
     *      Skips the balance reserved by the pending withdrawal request unless `useReserved` is set.
     *      Collateral is sized with Aave's own oracle prices and collateral factors (collateralForValue).
     * @return The weighted collateral value shortfall left after the pass
     */
    function _sizeResupply(CashModuleStorageContract.CashModuleStorage storage $, ILendGateway gateway, address safe, address[] memory tokens, uint256[] memory supplyAmounts, uint256 shortfallValue, bool useReserved) private view returns (uint256) {
        for (uint256 i = 0; i < tokens.length && shortfallValue != 0; i++) {
            // A zero-LTV asset adds no borrowing headroom, so supplying it cannot help
            if (gateway.ltv(tokens[i]) == 0) continue;

            // Loose balance still available for this token, net of what an earlier pass already claimed
            uint256 capacity = IERC20(tokens[i]).balanceOf(safe) - supplyAmounts[i];
            if (!useReserved) {
                // First pass: leave the pending withdrawal's reservation untouched
                uint256 pending = _pendingWithdrawalAmount($, safe, tokens[i]);
                capacity = capacity > pending ? capacity - pending : 0;
            }
            if (capacity == 0) continue;

            // Full cover fits in this token: take it and stop
            uint256 needed = gateway.collateralForValue(tokens[i], shortfallValue);
            if (needed <= capacity) {
                supplyAmounts[i] += needed;
                return 0;
            }

            // Partial cover: exhaust this token and carry the rest to the next one.
            // Taking capacity of the needed amount covers the same fraction of the shortfall; floor keeps the remainder conservative
            supplyAmounts[i] += capacity;
            shortfallValue -= (shortfallValue * capacity) / needed;
        }
        return shortfallValue;
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
        if (!_usesLendGateway($, safe)) {
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
        s.hasDebt = $.gateway.hasDebt(safe);
        // Aave-priced at the raw 1.00 bound: an authorized debit settles to Aave's own boundary, not the
        // configured floor (the lens buffers its quotes with withdrawHeadroom instead)
        s.withdrawHeadroom = s.hasDebt ? $.gateway.rawWithdrawHeadroom(safe) : 0;
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
        // The debit-spend gate, not the borrow gate: a debit only transfers and withdraws, so frozen is fine
        if (!$.gateway.isSpendAsset(token)) revert UnsupportedToken();
        uint256 amount = LendSourcingLib.fromUsd(priceProvider, token, amountInUsd);

        uint256 loose = IERC20(token).balanceOf(safe);
        uint256 withdrawable = LendSourcingLib.withdrawableSupplied($.gateway, safe, token, s.withdrawHeadroom, s.hasDebt);
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
            uint256 used = $.gateway.headroomRemoved(safe, token, amount - fromLoose);
            s.withdrawHeadroom = s.withdrawHeadroom > used ? s.withdrawHeadroom - used : 0;
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
