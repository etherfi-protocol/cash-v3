// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
import { IPriceProvider } from "../../../../../src/interfaces/IPriceProvider.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title CashModuleSpendAaveTest
 * @notice The gateway-path spend execution: debit sourcing (loose then Aave-supplied, capped by the borrowing
 *         headroom) and the credit resupply-then-borrow flow, all against a real Aave v4 instance. Positions are
 *         built through real supply / borrow, and the effects are asserted on observable state (settlement
 *         dispatcher receipts, gw.suppliedOf / gw.debtOf, and events) rather than mock call recorders.
 * @dev Legacy-engine spend tests (_forceLegacyEngine) and the loose-balance / validation spend tests that never
 *      read a gateway position stay in test/safe/modules/cash/Spend.t.sol (default profile). Run with:
 *      source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/Spend.t.sol"
 */
contract CashModuleSpendAaveTest is CashGatewayTestSetup {
    /// @dev RESUPPLY_BUFFER_BPS in CashLendLib; keep in sync.
    uint256 internal constant RESUPPLY_BUFFER_BPS = 10;

    // ================ debit sourcing ================

    /// A debit spend whose supplied withdrawal exceeds the borrowing headroom reverts.
    function test_spend_debit_reverts_whenWithdrawalExceedsBorrowHeadroom() public {
        // 100 USDC supplied at 80%, 40 borrowed: headroom $40 caps the supplied withdrawal at $50, so a $60 draw fails.
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _borrowOnGateway(address(safe), address(usdc), 40e6, recipient);
        deal(address(usdc), address(safe), 0);

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(60e6), _noCashback());
    }

    /// A debit spend at exactly the lens-reported max withdraws from Aave to the dispatcher (canSpend and spend agree at the boundary).
    function test_spend_debit_succeeds_atBorrowHeadroom() public {
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _borrowOnGateway(address(safe), address(usdc), 40e6, recipient);
        deal(address(usdc), address(safe), 0);

        uint256 cap = cashLens.getMaxSpendDebit(address(safe), _tokens(address(usdc))).spendableAmounts[0];
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(cap), _noCashback());

        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + cap, "spend routed to dispatcher");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), suppliedBefore - cap, 2, "withdrawn from the Aave-supplied balance");
    }

    /// Supply that carries no borrowing power (collateral flag off) is fully withdrawable for a debit even
    /// while the safe carries debt: removing it cannot lower the health factor, so Aave allows it.
    function test_spend_debit_withdrawsNonCollateralSupplyWithDebt() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether); // backs the debt
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _borrowOnGateway(address(safe), address(usdc), 40e6, recipient);
        vm.prank(driver);
        gw.setUsingAsCollateral(address(safe), address(usdc), false); // Aave allows it: weETH covers the debt
        deal(address(usdc), address(safe), 0);

        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(50e6), _noCashback());

        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 50e6, "spend routed to dispatcher");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 50e6, 2, "withdrawn from the non-collateral supplied balance");
    }

    /// Debit quote/execution agreement under Cash/Aave price divergence: the quote executes exactly on
    /// unchanged state and a cent past it is declined.
    function test_spend_debit_quoteExecutesExactly_underDivergence() public {
        _supplyToGateway(address(safe), address(usdc), 1000e6);
        _borrowOnGateway(address(safe), address(usdc), 300e6, recipient);
        deal(address(usdc), address(safe), 0);

        // Cash overvalues USDC 1.5x against Aave: the old Cash-priced headroom would overquote
        uint256 cashUsdcPrice = priceProvider.price(address(usdc));
        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(usdc)), abi.encode((cashUsdcPrice * 3) / 2));

        uint256 quote = cashLens.getMaxSpendDebit(address(safe), _tokens(address(usdc))).totalSpendableInUsd;
        assertGt(quote, 0, "position quotes debit capacity");

        (bool okOver,) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(quote + 1e4));
        assertFalse(okOver, "a cent past the quote is declined");

        (bool ok, string memory reason) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(quote));
        assertTrue(ok, reason);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(quote), _noCashback());
        assertTrue(cashModule.transactionCleared(address(safe), txId), "the quote executes exactly");
    }

    /// Over the borrow limit (zero headroom with debt), a loose-only spend is still allowed and does not touch Aave.
    function test_spend_debit_looseOnly_whenOverBorrowLimit() public {
        // Borrow the whole power so headroom is zero, then fund a loose balance for the spend.
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _borrowOnGateway(address(safe), address(usdc), 80e6, recipient);
        deal(address(usdc), address(safe), 100e6);

        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(100e6), _noCashback());

        assertEq(usdc.balanceOf(address(safe)), 0, "loose balance drained");
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 100e6, "spend routed to dispatcher");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), suppliedBefore, "no Aave withdrawal despite exhausted headroom");
    }

    /// A debit spend draws the loose balance first, then withdraws the shortfall from the Aave-supplied balance.
    function test_spend_debit_drawsLooseThenWithdrawsSupplied() public {
        // No debt, so the supplied side is not headroom-capped: 40 loose plus a 60 withdrawal covers a 100 spend.
        _supplyToGateway(address(safe), address(usdc), 100e6);
        deal(address(usdc), address(safe), 40e6);

        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(100e6), _noCashback());

        assertEq(usdc.balanceOf(address(safe)), 0, "loose balance spent");
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 100e6, "full spend routed to dispatcher");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 100e6 - 60e6, 2, "60 shortfall withdrawn from Aave");
    }

    /// A debit spend preserves a pending withdrawal when the supplied balance covers the loose shortfall.
    function test_spend_debit_preservesPendingWithdrawal_whenSuppliedCoversShortfall() public {
        // 100 loose with 40 reserved by a pending withdrawal; an 80 spend takes the 60 unreserved plus 20 from Aave.
        _supplyToGateway(address(safe), address(usdc), 200e6);
        deal(address(usdc), address(safe), 100e6);
        _requestWithdrawal(_tokens(address(usdc)), _amounts(40e6), withdrawRecipient);

        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(80e6), _noCashback());

        assertEq(usdc.balanceOf(address(safe)), 40e6, "reserved balance stays for the withdrawal");
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 80e6, "spend routed to dispatcher");
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 40e6, "pending withdrawal survives");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 200e6 - 20e6, 2, "20 shortfall withdrawn from Aave");
    }

    /// A freeze does not stop debit: the loose leg is a plain transfer and the supplied leg is an Aave
    /// withdraw, both allowed on a frozen reserve, so the spend lands.
    function test_spend_debit_succeeds_whileReserveFrozen() public {
        _supplyToGateway(address(safe), address(usdc), 100e6);
        deal(address(usdc), address(safe), 40e6);
        _setAaveReserveFrozen(usdcReserveId, true);

        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(100e6), _noCashback());

        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 100e6, "loose plus supplied funded the spend while frozen");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 100e6 - 60e6, 2, "shortfall withdrawn from the frozen reserve");
    }

    /// A debit spend does not need the reserve to be borrowable: membership is the admin spend set, so a
    /// supply-only reserve (borrowable flag off, e.g. a stable listed only to hold and spend) still funds a
    /// debit spend from loose balance plus an Aave withdraw.
    function test_spend_debit_succeeds_whenReserveNotBorrowable() public {
        _supplyToGateway(address(safe), address(usdc), 100e6);
        deal(address(usdc), address(safe), 40e6);
        _setAaveReserveBorrowable(usdcReserveId, false);
        assertFalse(gw.isBorrowable(address(usdc)), "reserve is supply-only");
        assertTrue(gw.isSpendAsset(address(usdc)), "still a declared spend asset");

        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(100e6), _noCashback());

        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 100e6, "loose plus supplied funded the spend on a supply-only reserve");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 100e6 - 60e6, 2, "shortfall withdrawn from the supply-only reserve");
    }

    /// Audit I-02: a paused reserve must not block a debit spend the safe can fund entirely from loose
    /// balance — no Aave interaction is needed, and an opted-out safe (forced into Debit, everything loose)
    /// would otherwise have card settlement blocked by an Aave pause it does not depend on.
    function test_spend_debit_succeeds_fromLooseWhileReservePaused() public {
        deal(address(usdc), address(safe), 100e6);
        _setAaveReservePaused(usdcReserveId, true);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(100e6), _noCashback());

        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 100e6, "loose balance settled the spend during the pause");
    }

    /// The pause still binds the part a debit spend cannot fund loose: withdrawalLiquidity reads zero for a
    /// paused reserve, so the supplied leg is unavailable and the spend declines on balance, not membership.
    function test_spend_debit_revertsWhenPausedAndNeedsSuppliedLeg() public {
        _supplyToGateway(address(safe), address(usdc), 100e6);
        deal(address(usdc), address(safe), 40e6);
        _setAaveReservePaused(usdcReserveId, true);

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(100e6), _noCashback());
    }

    /// A paused reserve cannot fund a CREDIT spend: the borrow gate (isBorrowable) reads the pause itself, so
    /// the typed rejection survives making the debit gate pause-agnostic.
    function test_spend_credit_reverts_whenReservePaused() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        _enterCreditMode();
        _setAaveReservePaused(usdcReserveId, true);

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.UnsupportedToken.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(10e6), _noCashback());
    }

    /// The auth-vs-freeze race: an auth approved while the reserve was borrowable cannot settle once the
    /// reserve is frozen. The spend reverts on the module's gate — the same predicate the auth now declines
    /// on — instead of deep inside Aave.
    function test_spend_credit_reverts_whenReserveFrozenAfterAuth() public {
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _enterCreditMode();

        _setAaveReserveFrozen(usdcReserveId, true);

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.UnsupportedToken.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(10e6), _noCashback());
    }

    // ================ credit authorization pricing ================

    /// Cash must not approve more debt merely because its payment oracle values collateral above Aave's oracle.
    function test_spend_credit_declinesWhenCashOvervaluesCollateralAgainstAave() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        deal(address(weETH), address(safe), 0);
        deal(address(usdc), address(safe), 0);
        _enterCreditMode();

        uint256 aaveCapacity = gw.borrowCapacity(address(safe), address(usdc));
        uint256 cashWeethPrice = priceProvider.price(address(weETH));
        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(weETH)), abi.encode(cashWeethPrice * 2));

        uint256 spendUsd = (aaveCapacity * 120) / 100;
        (bool ok, string memory reason) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(spendUsd));
        assertFalse(ok);
        assertEq(reason, "Insufficient borrowing power");
    }

    /// Credit max-spend must remain bounded by Aave when Cash values collateral more highly.
    function test_maxSpendCredit_usesAavePricedBorrowCapacity() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        _enterCreditMode();

        uint256 cashWeethPrice = priceProvider.price(address(weETH));
        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(weETH)), abi.encode(cashWeethPrice * 2));

        uint256 capacity = gw.borrowCapacity(address(safe), address(usdc));
        uint256 expectedUsd = (capacity * priceProvider.price(address(usdc))) / 1e6;
        assertEq(cashLens.getMaxSpendCredit(address(safe)), expectedUsd);
    }

    /// The Aave-priced max is accepted and executes unchanged; one token unit above it is declined.
    function test_spend_credit_executesAtAavePricedMax() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        deal(address(weETH), address(safe), 0);
        deal(address(usdc), address(safe), 0);
        _enterCreditMode();

        uint256 maxSpendUsd = cashLens.getMaxSpendCredit(address(safe));
        (bool aboveOk, string memory aboveReason) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(maxSpendUsd + 1));
        assertFalse(aboveOk);
        assertEq(aboveReason, "Insufficient borrowing power");

        (bool maxOk, string memory maxReason) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(maxSpendUsd));
        assertTrue(maxOk, maxReason);
        _creditSpendUsdc(maxSpendUsd);
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), maxSpendUsd, 2);
    }

    /// An accepted sub-token payment rounds the borrowed amount up, so unchanged-state execution cannot hit AmountZero.
    function test_spend_credit_roundsBorrowAmountUp() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        _enterCreditMode();

        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(usdc)), abi.encode(2e6));
        (bool ok, string memory reason) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(1));
        assertTrue(ok, reason);

        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        _creditSpendUsdc(1);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 1);
    }

    /// Aave-covered credit must not consume collateral reserved by a pending withdrawal because Cash prices it lower.
    function test_spend_credit_preservesWithdrawalWhenAaveCapacityAlreadyCovers() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        deal(address(usdc), address(safe), 100e6);
        _requestWithdrawal(_tokens(address(usdc)), _amounts(100e6), withdrawRecipient);
        _enterCreditMode();

        uint256 spendUsd = (gw.borrowCapacity(address(safe), address(usdc)) * 60) / 100;
        uint256 cashWeethPrice = priceProvider.price(address(weETH));
        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(weETH)), abi.encode(cashWeethPrice / 2));

        (bool ok, string memory reason) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(spendUsd));
        assertTrue(ok, reason);
        _creditSpendUsdc(spendUsd);

        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 100e6);
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0);
    }

    /// Cash must check the actual token amount when its payment oracle values the borrowed token below Aave.
    function test_spend_credit_declinesWhenCashUndervaluesBorrowTokenAgainstAave() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        deal(address(weETH), address(safe), 0);
        deal(address(usdc), address(safe), 0);
        _enterCreditMode();

        uint256 aaveCapacity = gw.borrowCapacity(address(safe), address(usdc));
        uint256 cashUsdcPrice = priceProvider.price(address(usdc));
        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(usdc)), abi.encode(cashUsdcPrice / 2));

        uint256 spendUsd = (aaveCapacity * 60) / 100;
        (bool ok, string memory reason) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(spendUsd));
        assertFalse(ok);
        assertEq(reason, "Insufficient borrowing power");
    }

    /// With a 1.05 floor set, a new auth is declined at the floor while an already-authorized spend still executes
    /// in the 1.00-1.05 band using Aave's raw bound, resupplying nothing and leaving a pending withdrawal intact.
    function test_spend_credit_executesInFloorBandWithoutResupply() public {
        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        deal(address(usdc), address(safe), 0);
        _enterCreditMode();

        // Spend to the buffered (1.05) max: health factor lands at the floor, so the buffered quote is exhausted
        // but the raw (1.00) quote still leaves room.
        _creditSpend(keccak256("band.max"), cashLens.getMaxSpendCredit(address(safe)));
        uint256 rawRoom = gw.rawBorrowCapacity(address(safe), address(usdc));
        assertGt(rawRoom, 0, "raw capacity remains between 1.05 and 1.00");
        assertLt(gw.borrowCapacity(address(safe), address(usdc)), rawRoom, "buffered quote exhausted at the floor");

        // A pending withdrawal of loose USDC: an unnecessary resupply would consume or cancel it.
        deal(address(usdc), address(safe), 100e6);
        _requestWithdrawal(_tokens(address(usdc)), _amounts(100e6), withdrawRecipient);

        uint256 bandSpend = rawRoom / 2;
        // A new auth for the band spend is declined at the 1.05 floor...
        (bool ok, string memory reason) = cashLens.canSpend(address(safe), keccak256("band.auth"), _tokens(address(usdc)), _amounts(bandSpend));
        assertFalse(ok);
        assertEq(reason, "Insufficient borrowing power");

        // ...but the already-authorized spend executes against Aave's raw bound, with no resupply or cancellation.
        _creditSpend(keccak256("band.spend"), bandSpend);
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "no USDC resupplied");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), 1 ether, "collateral unchanged");
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 100e6, "pending withdrawal intact");
    }

    // ================ credit resupply: supply loose collateral when the borrow doesn't fit ================

    /// Borrowing power already covers the spend, so nothing is resupplied and the borrow just goes through.
    function test_spend_creditResupply_skipped_whenCapacityCovers() public {
        _supplyToGateway(address(safe), address(usdc), 100e6); // ~$80 borrowing power at 80%
        _enterCreditMode();

        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(usdc));
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));

        _creditSpendUsdc(10e6);

        assertEq(gw.suppliedOf(address(safe), address(usdc)), suppliedBefore, "no resupply when the borrow fits");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 10e6, 2, "borrow lands");
        assertApproxEqAbs(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 10e6, 2, "borrow routed to dispatcher");
    }

    /// A one-token shortfall supplies the exact buffered amount, flags it as collateral, and the borrow lands.
    function test_spend_creditResupply_suppliesOneToken() public {
        // Nothing supplied yet: the whole $10 spend is the shortfall, covered by resupplying loose USDC.
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();

        uint256 expected = _resupplyAmount(address(usdc), 10e6);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.CollateralResupplied(address(safe), address(usdc), expected);
        _creditSpendUsdc(10e6);

        assertEq(gw.suppliedOf(address(safe), address(usdc)), expected, "resupplies the buffered amount");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 10e6, 2, "borrow lands");
        assertApproxEqAbs(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 10e6, 2, "borrow routed to dispatcher");
    }

    /// The unreserved loose balance covers the shortfall, so the pending withdrawal request survives.
    function test_spend_creditResupply_prefersUnreserved_keepsWithdrawal() public {
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();
        _requestWithdrawal(_tokens(address(usdc)), _amounts(50e6), withdrawRecipient);

        // The buffered amount (~$12.5) fits in the 50 unreserved, so the request is untouched.
        _creditSpendUsdc(10e6);

        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 50e6, "pending withdrawal survives");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), _resupplyAmount(address(usdc), 10e6), "resupplied from the unreserved balance");
    }

    /// Covering the shortfall needs withdrawal-reserved balance: the request is cancelled and the dip is supplied.
    function test_spend_creditResupply_dipsIntoReserved_cancelsWithdrawal() public {
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();
        address[] memory tokens = _tokens(address(usdc));
        uint256[] memory amounts = _amounts(95e6);
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Unreserved is 5; pass one takes it, pass two cancels the request and supplies the residual.
        uint256 shortfallValue = _bufferedShortfallValue(10e6);
        uint256 fullNeeded = gw.collateralForValue(address(usdc), shortfallValue);
        uint256 expected = 5e6 + gw.collateralForValue(address(usdc), _residualValue(shortfallValue, 5e6, fullNeeded));

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalCancelled(address(safe), tokens, amounts, withdrawRecipient);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.CollateralResupplied(address(safe), address(usdc), expected);
        _creditSpendUsdc(10e6);

        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 0, "request cancelled to fund the spend");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), expected, "supplied the unreserved plus the reserved dip");
    }

    /// Another token's loose balance covers the shortfall, so the reserved token's request survives.
    function test_spend_creditResupply_otherTokenCovers_keepsWithdrawal() public {
        _setAaveCollateralFactor(address(weETH), 5000);
        deal(address(usdc), address(safe), 50e6);
        deal(address(weETH), address(safe), 1 ether);
        _enterCreditMode();

        // The whole USDC balance is reserved by the request, so loose weETH must cover without touching it.
        _requestWithdrawal(_tokens(address(usdc)), _amounts(50e6), withdrawRecipient);

        _creditSpendUsdc(10e6);

        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 50e6, "reserved USDC request survives");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), _resupplyAmount(address(weETH), 10e6), "weETH covers the shortfall");
    }

    /// Resupply sizes collateral with Aave prices: Cash overvaluing weETH must not shrink the supplied
    /// amount (the old Cash-priced sizing would supply half of what Aave requires and the borrow would revert).
    function test_spend_creditResupply_sizesWithAavePrices_whenCashOvervalues() public {
        _setAaveCollateralFactor(address(weETH), 5000);
        deal(address(weETH), address(safe), 1 ether);
        _enterCreditMode();
        uint256 expected = _resupplyAmount(address(weETH), 10e6); // Aave-priced, independent of the Cash skew

        uint256 cashWeethPrice = priceProvider.price(address(weETH));
        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(weETH)), abi.encode(cashWeethPrice * 2));

        _creditSpendUsdc(10e6);
        assertEq(gw.suppliedOf(address(safe), address(weETH)), expected, "supplied the Aave-priced amount despite the Cash skew");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 10e6, 2, "borrow lands");
    }

    /// The mirror direction: Cash undervaluing weETH must not over-supply beyond the Aave-priced amount.
    function test_spend_creditResupply_noOversupply_whenCashUndervalues() public {
        _setAaveCollateralFactor(address(weETH), 5000);
        deal(address(weETH), address(safe), 1 ether);
        _enterCreditMode();
        uint256 expected = _resupplyAmount(address(weETH), 10e6);

        uint256 cashWeethPrice = priceProvider.price(address(weETH));
        vm.mockCall(address(priceProvider), abi.encodeWithSelector(IPriceProvider.price.selector, address(weETH)), abi.encode(cashWeethPrice / 2));

        _creditSpendUsdc(10e6);
        assertEq(gw.suppliedOf(address(safe), address(weETH)), expected, "supplied the Aave-priced amount, not the doubled Cash-priced one");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 10e6, 2, "borrow lands");
    }

    /// With no eligible loose collateral, nothing is supplied and the failing borrow reverts the whole spend.
    function test_spend_creditResupply_noEligibleCollateral_borrowReverts() public {
        // Nothing supplied and nothing loose to resupply: the borrow against an empty position is rejected by Aave.
        _enterCreditMode();

        vm.prank(etherFiWallet);
        vm.expectRevert(ISpoke.HealthFactorBelowThreshold.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(10e6), _noCashback());

        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "nothing supplied on the reverted spend");
    }

    /// A shortfall spanning tokens exhausts the first registered asset and covers the proportional remainder from the next.
    function test_spend_creditResupply_multipleTokens_partialCover() public {
        // Registered order is [weETH, usdc]: the small weETH balance is exhausted first, USDC covers the rest.
        _setAaveCollateralFactor(address(weETH), 5000);
        deal(address(weETH), address(safe), 0.001 ether);
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();

        uint256 shortfallValue = _bufferedShortfallValue(10e6);
        uint256 neededWeeth = gw.collateralForValue(address(weETH), shortfallValue);
        uint256 expectedUsdc = gw.collateralForValue(address(usdc), _residualValue(shortfallValue, 0.001 ether, neededWeeth));

        _creditSpendUsdc(10e6);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0.001 ether, "small weETH balance fully supplied first");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), expectedUsdc, "USDC covers the proportional remainder");
    }

    /// A frozen reserve would revert the whole spend at supply time: sizing skips it (headroom zero) and the
    /// next registered token covers the shortfall, even though the frozen one is first and could fully cover.
    function test_spend_creditResupply_skipsFrozenReserve_nextTokenCovers() public {
        deal(address(weETH), address(safe), 1 ether);
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();
        _setAaveReserveFrozen(weethReserveId, true);

        _creditSpendUsdc(10e6);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "frozen weETH skipped");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), _resupplyAmount(address(usdc), 10e6), "USDC covers the whole shortfall");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 10e6, 2, "borrow lands");
    }

    /// The paused sibling: a paused reserve is skipped the same way.
    function test_spend_creditResupply_skipsPausedReserve_nextTokenCovers() public {
        deal(address(weETH), address(safe), 1 ether);
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();
        _setAaveReservePaused(weethReserveId, true);

        _creditSpendUsdc(10e6);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "paused weETH skipped");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), _resupplyAmount(address(usdc), 10e6), "USDC covers the whole shortfall");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 10e6, 2, "borrow lands");
    }

    /// A reserve near its addCap contributes exactly its remaining cap room (not skipped outright, not
    /// oversized into an AddCapExceeded revert) and the next token covers the proportional remainder.
    function test_spend_creditResupply_atCapUsesPartialHeadroom_thenNextToken() public {
        // Someone else's supply fills most of a 1-token weETH addCap without giving the safe any capacity
        _seedAaveLiquidity(weethReserveId, address(weETH), 0.999 ether);
        _setAaveSpokeCaps(weethReserveId, 1, type(uint40).max);
        deal(address(weETH), address(safe), 1 ether);
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();

        uint256 headroom = gw.supplyHeadroom(address(weETH));
        uint256 shortfallValue = _bufferedShortfallValue(10e6);
        uint256 neededWeeth = gw.collateralForValue(address(weETH), shortfallValue);
        assertLt(headroom, neededWeeth, "cap room must be the binding limit for this test to bite");
        uint256 expectedUsdc = gw.collateralForValue(address(usdc), _residualValue(shortfallValue, headroom, neededWeeth));

        _creditSpendUsdc(10e6);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), headroom, "weETH fills exactly its remaining cap room");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), expectedUsdc, "USDC covers the proportional remainder");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 10e6, 2, "borrow lands");
    }

    /// Audit L-08: a pre-existing deficit (a price crash parked the position under Aave's 1.00 before
    /// liquidation caught it) is invisible to the clamped rawBorrowCapacity, so resupply used to size
    /// collateral for the new borrow only and the settlement borrow reverted on Aave's whole-position
    /// health check — with ample loose collateral sitting in the safe. Sizing now adds deficitValue:
    /// the spend settles and the resupply incidentally restores the position to at or above 1.00.
    function test_spend_creditResupply_coversPreexistingDeficit() public {
        _enterCreditMode();
        // Lever an existing position to ~98% of raw capacity, then crash weETH 15%
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 0);
        _borrowOnGateway(address(safe), address(usdc), (gw.rawBorrowCapacity(address(safe), address(usdc)) * 98) / 100, recipient);
        _crashWeethAavePrice(8500);
        assertLt(spoke.getUserAccountData(address(safe)).healthFactor, 1e18, "underwater before the spend");
        uint256 debtBefore = gw.debtOf(address(safe), address(usdc));

        // Ample loose collateral: enough for the deficit and the new borrow's cover
        deal(address(weETH), address(safe), 1 ether);

        _creditSpendUsdc(10e6);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)) - debtBefore, 10e6, 2, "settlement borrow landed");
        assertGe(spoke.getUserAccountData(address(safe)).healthFactor, 1e18, "resupply covered the deficit too");
    }

    /// Every candidate unsuppliable (weETH frozen, USDC at its addCap): nothing is supplied and the failing
    /// borrow reverts the whole spend, same terminal error as the no-eligible-collateral case.
    function test_spend_creditResupply_allUnsuppliable_borrowReverts() public {
        deal(address(weETH), address(safe), 1 ether);
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();
        _setAaveReserveFrozen(weethReserveId, true);
        // The seeded 1M USDC liquidity fills a 1M-token addCap exactly; USDC stays borrowable and spendable
        _setAaveSpokeCaps(usdcReserveId, 1_000_000, type(uint40).max);
        assertEq(gw.supplyHeadroom(address(usdc)), 0, "USDC reserve at its cap");

        vm.prank(etherFiWallet);
        vm.expectRevert(ISpoke.HealthFactorBelowThreshold.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(10e6), _noCashback());

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "nothing supplied on the reverted spend");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "nothing supplied on the reverted spend");
    }

    // ================ helpers ================

    function _enterCreditMode() internal {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
    }

    function _creditSpendUsdc(uint256 amountInUsd) internal {
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(amountInUsd), _noCashback());
    }

    /// @dev USDC credit spend under a caller-chosen txId, for tests that spend more than once.
    function _creditSpend(bytes32 spendTxId, uint256 amountInUsd) internal {
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spendTxId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(amountInUsd), _noCashback());
    }

    /// @dev Mirrors the Aave-priced resupply pipeline: the spend's USDC borrow amount (Cash-priced payment
    ///      conversion, ceil), valued by the gateway at Aave prices (borrowValue) and buffered once at entry.
    function _bufferedShortfallValue(uint256 spendUsd) internal view returns (uint256) {
        uint256 price = priceProvider.price(address(usdc));
        uint256 shortfallTokens = (spendUsd * 1e6 + price - 1) / price;
        uint256 value = gw.borrowValue(address(usdc), shortfallTokens);
        return (value * (10_000 + RESUPPLY_BUFFER_BPS) + 9999) / 10_000;
    }

    /// @dev Mirrors _sizeResupply's full-cover sizing when one token covers the whole spend's shortfall.
    function _resupplyAmount(address token, uint256 spendUsd) internal view returns (uint256) {
        return gw.collateralForValue(token, _bufferedShortfallValue(spendUsd));
    }

    /// @dev Mirrors the partial-cover remainder: taking `capacity` of `needed` covers the same fraction of the shortfall.
    function _residualValue(uint256 shortfallValue, uint256 capacity, uint256 needed) internal pure returns (uint256) {
        return shortfallValue - (shortfallValue * capacity) / needed;
    }

    function _tokens(address token) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = token;
        return arr;
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = amount;
        return arr;
    }

    function _noCashback() internal pure returns (Cashback[] memory) {
        Cashback[] memory cashbacks;
        return cashbacks;
    }
}

/// @dev Runs the suite's setup with weETH's reserve flipped to borrowable while it stays OFF the
///      spend-asset list: a credit spend settles the card, so a borrowable-but-not-settleable token must
///      be rejected on both the check side and the execution side.
contract SpendCreditTokenGateTest is CashModuleSpendAaveTest {
    function _weethBorrowable() internal pure override returns (bool) {
        return true;
    }

    function test_creditSpend_rejectsBorrowableNonSpendAsset() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _setMode(Mode.Credit);

        assertTrue(gw.isBorrowable(address(weETH)), "premise: weETH borrowable");
        assertFalse(gw.isSpendAsset(address(weETH)), "premise: weETH not a spend asset");

        // The lens declines it...
        (bool ok, string memory reason) = cashLens.canSpend(address(safe), txId, _tokens(address(weETH)), _amounts(100e6));
        assertFalse(ok, "lens declines the non-settleable token");
        assertEq(reason, "Not a supported borrow token");

        // ...and execution rejects it identically (check/execution parity)
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.UnsupportedToken.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(weETH)), _amounts(100e6), _noCashback());

        // The card settlement token (borrowable AND spend asset) is unaffected
        (bool okUsdc,) = cashLens.canSpend(address(safe), txId, _tokens(address(usdc)), _amounts(100e6));
        assertTrue(okUsdc, "usdc credit spend unaffected");
    }
}
