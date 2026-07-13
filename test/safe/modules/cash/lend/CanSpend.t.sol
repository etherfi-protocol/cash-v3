// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title CashLensCanSpendAaveTest
 * @notice The gateway-path canSpend tests: credit-mode borrowing power, reserve liquidity, and debit against
 *         an Aave-supplied balance, all built through real supply/borrow flows against a real Aave v4 instance.
 *         The debit-only / spending-limit / txId / validation canSpend tests that never read a gateway position
 *         stay in test/safe/modules/cash/CanSpend.t.sol (default profile, mock gateway as inert plumbing).
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/CanSpend.t.sol"
 */
contract CashLensCanSpendAaveTest is CashGatewayTestSetup {
    /// Debit spend succeeds when the stable is supplied to Aave rather than held loose, drawing on the withdrawable balance.
    function test_canSpend_succeeds_inDebitMode_whenSuppliedToAave() public {
        // The stable is supplied to Aave, not held loose. Debit still works via the withdrawable amount.
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        _supplyToGateway(address(safe), address(usdc), 1000e6); // supplied, no loose balance

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    /// Credit spend succeeds when the supplied collateral gives enough borrowing power to cover the amount.
    function test_canSpend_succeeds_inCreditMode_whenCollateralAvailable() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        _supplyToGateway(address(safe), address(weETH), 1 ether);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    /// An otherwise-fine credit spend is declined once the borrow reserve is frozen: canSpend gates on the same
    /// borrow gate Aave enforces at spend, so auth and the on-chain borrow cannot disagree.
    function test_canSpend_fails_inCreditMode_whenBorrowReserveFrozen() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        _supplyToGateway(address(safe), address(weETH), 1 ether);

        // Ample borrowing power, but freezing the USDC reserve makes it non-borrowable
        _setAaveReserveFrozen(usdcReserveId, true);

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Not a supported borrow token");
    }

    /// Credit spend is declined when borrowing power is ample but the Aave reserve holds too little cash for the loan.
    function test_canSpend_fails_inCreditMode_whenReserveLiquidityUnavailable() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        // Ample borrowing power, but the reserve holds less cash than the loan needs. Reaching a genuinely
        // drained reserve on real Aave takes an unrelated whale borrow, so the reserve read is mocked here to
        // isolate CashLens's liquidity gate (the branch under test).
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        vm.mockCall(address(gw), abi.encodeWithSelector(ILendGateway.availableCash.selector, address(usdc)), abi.encode(amounts[0] - 1));

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient liquidity to cover the loan");
    }

    /// Credit spend succeeds when a pending withdrawal sits against loose funds and the borrow stays within the supplied position's power.
    function test_canSpend_succeeds_inCreditMode_whenAfterWithdrawalAmountIsStillBorrowable() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        // 800 USDC supplied as collateral, 200 loose with a pending withdrawal against the loose balance.
        _supplyToGateway(address(safe), address(usdc), 800e6);
        deal(address(usdc), address(safe), 200e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // A pending withdrawal sits against the loose balance, not the supplied collateral, so a credit borrow
        // well within the supplied position's power is still fine.
        amounts[0] = 400e6;
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    /// Credit spend is declined when the requested borrow exceeds the collateral's borrowing power (reserved withdrawal is the deciding factor).
    function test_canSpend_fails_inCreditMode_whenWithdrawalRequestBlocksIt() public {
        // 90% collateral factor so the reserved withdrawal is the deciding factor (81 borrowable vs 82 requested).
        _setAaveCollateralFactor(address(usdc), 9000);

        // 90 USDC supplied as collateral, 10 loose with a pending withdrawal.
        _supplyToGateway(address(safe), address(usdc), 90e6);
        deal(address(usdc), address(safe), 10e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        _setMode(Mode.Credit);

        // 90 USDC * 90% = 81 borrowable, so 82 must be declined.
        amounts[0] = 82e6;
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient borrowing power");
    }

    /// Credit spend is declined when nothing is supplied, so the safe has no borrowing power.
    function test_canSpend_fails_inCreditMode_whenCollateralBalanceIsZero() public {
        _setMode(Mode.Credit);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;

        // Fresh gateway safe has nothing supplied, so no borrowing power.
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient borrowing power");
    }

    /// canSpendSingleToken picks credit mode and USDC when supplied collateral covers the amount.
    function test_canSpendSingleToken_creditMode_works() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        _supplyToGateway(address(safe), address(weETH), 1 ether);

        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdc);
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdc);

        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, 500e6);

        assertEq(uint8(mode), uint8(Mode.Credit), "Should return credit mode");
        assertEq(token, address(usdc), "Should return USDC");
        assertTrue(canSpend, "Should be able to spend in credit mode");
        assertEq(message, "", "Should have no error message");
    }

    /// canSpendSingleToken returns credit mode but declines when no collateral backs the borrow.
    function test_canSpendSingleToken_creditModeWithInsufficientCollateral() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdc);
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdc);

        // No supplied collateral -> no borrowing power.
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, 500e6);

        assertEq(uint8(mode), uint8(Mode.Credit), "Should return credit mode");
        assertEq(token, address(usdc), "Should return USDC");
        assertFalse(canSpend, "Should not be able to spend without collateral");
        assertEq(message, "Insufficient borrowing power", "Should indicate borrowing power issue");
    }
}
