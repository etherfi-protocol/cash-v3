// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
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

    /// A zero-LTV reserve cannot fund a debit while the safe carries debt, so the spend reverts.
    function test_spend_debit_reverts_whenWithdrawingZeroLtvCollateralWithDebt() public {
        // Aave rejects a 0 collateral factor, so the defensive zero-LTV branch is exercised by mocking gw.ltv.
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _borrowOnGateway(address(safe), address(usdc), 40e6, recipient);
        deal(address(usdc), address(safe), 0);
        vm.mockCall(address(gw), abi.encodeWithSelector(ILendGateway.ltv.selector, address(usdc)), abi.encode(uint256(0)));

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(50e6), _noCashback());
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

        uint256 expected = _resupplyAmount(address(usdc), 80e18, 10e6);
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
        assertEq(gw.suppliedOf(address(safe), address(usdc)), _resupplyAmount(address(usdc), 80e18, 10e6), "resupplied from the unreserved balance");
    }

    /// Covering the shortfall needs withdrawal-reserved balance: the request is cancelled and the dip is supplied.
    function test_spend_creditResupply_dipsIntoReserved_cancelsWithdrawal() public {
        deal(address(usdc), address(safe), 100e6);
        _enterCreditMode();
        address[] memory tokens = _tokens(address(usdc));
        uint256[] memory amounts = _amounts(95e6);
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Unreserved is 5; pass one takes it, pass two cancels the request and supplies the residual.
        uint256 fullNeeded = _resupplyAmount(address(usdc), 80e18, 10e6);
        uint256 residualUsd = _residualUsd(10e6, 5e6, fullNeeded);
        uint256 expected = 5e6 + _resupplyAmount(address(usdc), 80e18, residualUsd);

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
        assertEq(gw.suppliedOf(address(safe), address(weETH)), _resupplyAmount(address(weETH), 50e18, 10e6), "weETH covers the shortfall");
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

        uint256 residualUsd = _residualUsd(10e6, 0.001 ether, _resupplyAmount(address(weETH), 50e18, 10e6));
        uint256 expectedUsdc = _resupplyAmount(address(usdc), 80e18, residualUsd);

        _creditSpendUsdc(10e6);

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0.001 ether, "small weETH balance fully supplied first");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), expectedUsdc, "USDC covers the proportional remainder");
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

    /// @dev Mirrors CashLendLib._resupplyAmount: token amount whose LTV-weighted value covers neededUsd, ceil + buffer.
    function _resupplyAmount(address token, uint256 tokenLtv, uint256 neededUsd) internal view returns (uint256) {
        uint256 num = neededUsd * 100e18 * (10 ** IERC20Metadata(token).decimals()) * (10_000 + RESUPPLY_BUFFER_BPS);
        uint256 den = tokenLtv * priceProvider.price(token) * 10_000;
        return (num + den - 1) / den;
    }

    /// @dev Mirrors the partial-cover remainder: taking `capacity` of `needed` covers the same fraction of the shortfall.
    function _residualUsd(uint256 shortfallUsd, uint256 capacity, uint256 needed) internal pure returns (uint256) {
        return shortfallUsd - (shortfallUsd * capacity) / needed;
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
