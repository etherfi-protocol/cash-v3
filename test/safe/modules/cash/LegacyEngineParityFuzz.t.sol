// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode } from "../../../../src/interfaces/ICashModule.sol";
import { ParityFuzzBase } from "./helpers/ParityFuzzBase.sol";

/**
 * @title LegacyEngineParityFuzzTest
 * @notice canSpend/spend parity fuzz for legacy-engine (DebtManager) safes: an approved check settles
 *         (eventually, inside a pending-mode window), and a declined-but-settled spend must be the
 *         pending-withdrawal cancellation asymmetry or the mode window. Amounts anchor to the lens quotes
 *         so runs cluster around the approve/decline boundary instead of wasting on far-off declines.
 * @dev Deterministic witnesses below prove every divergence class and the eventual-parity path are reachable.
 */
contract LegacyEngineParityFuzzTest is ParityFuzzBase {
    /// Routes the safe to the legacy engine and funds the DebtManager so credit spends can borrow.
    function setUp() public override {
        super.setUp();
        _forceLegacyEngine(address(safe));
        deal(address(usdc), address(debtManager), 1_000_000e6);
    }

    // The legacy engine has no engine-specific divergence classes: the base's observed pending-withdrawal cancellation
    // and the mode window are the only legitimate divergences, so _classify keeps its default.

    /// Single-element token array holding USDC, the spend token of every run.
    function _tokens() private view returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        return tokens;
    }

    /// Places a pending USDC withdrawal request of `amount`, reserving it from the loose balance.
    function _requestUsdcWithdrawal(uint256 amount) private {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        _requestWithdrawal(_tokens(), amounts, withdrawRecipient);
    }

    /// Debit parity across fuzzed balances, reservations (including one outgrowing the balance), and a
    /// pending Credit switch: the lens verdict must predict the spend outcome per the parity properties.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_parity_legacyDebit(uint256 balanceUsd, uint256 spendBpsOfQuote, uint256 withdrawalBpsOfBalance, bool drainBalanceBelowReservation, bool creditPending) public {
        balanceUsd = bound(balanceUsd, 10e6, 4000e6);
        spendBpsOfQuote = bound(spendBpsOfQuote, 1, 13_000);
        withdrawalBpsOfBalance = bound(withdrawalBpsOfBalance, 0, 10_000);

        deal(address(usdc), address(safe), balanceUsd);
        if (withdrawalBpsOfBalance > 0) {
            uint256 reservation = (balanceUsd * withdrawalBpsOfBalance) / 10_000;
            _requestUsdcWithdrawal(reservation);
            if (drainBalanceBelowReservation) {
                // Funds moved after the request, leaving the reservation larger than the balance by one
                // unit: the tightest form of the state whose unguarded subtraction used to underflow
                deal(address(usdc), address(safe), reservation - 1);
            }
        }
        if (creditPending) {
            // Opens the mode window: the lens previews Credit while execution stays Debit
            _setMode(Mode.Credit);
        }

        uint256 quote = cashLens.getMaxSpendDebit(address(safe), _tokens()).totalSpendableInUsd;
        uint256 amountUsd = (quote * spendBpsOfQuote) / 10_000;
        if (amountUsd == 0) {
            amountUsd = 1;
        }

        _assertParity(txId, address(usdc), amountUsd);
    }

    /// Credit parity across fuzzed collateral, reservations, and both sides of the mode-delay boundary:
    /// the lens verdict must predict the spend outcome per the parity properties.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_parity_legacyCredit(uint256 collateralUsd, uint256 spendBpsOfQuote, uint256 withdrawalBpsOfBalance, bool matured) public {
        collateralUsd = bound(collateralUsd, 10e6, 4000e6);
        spendBpsOfQuote = bound(spendBpsOfQuote, 1, 13_000);
        withdrawalBpsOfBalance = bound(withdrawalBpsOfBalance, 0, 10_000);

        // USDC doubles as legacy collateral, so the loose balance is the borrowing power's source
        deal(address(usdc), address(safe), collateralUsd);
        if (withdrawalBpsOfBalance > 0) {
            _requestUsdcWithdrawal((collateralUsd * withdrawalBpsOfBalance) / 10_000);
        }
        _setMode(Mode.Credit);
        if (matured) {
            vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        }

        uint256 quote = cashLens.getMaxSpendCredit(address(safe));
        uint256 amountUsd = (quote * spendBpsOfQuote) / 10_000;
        if (amountUsd == 0) {
            amountUsd = 1;
        }

        _assertParity(txId, address(usdc), amountUsd);
    }

    // ----------------------------------------------------------------- deterministic witnesses

    /// Divergence witness: the spend needs the reserved balance; the lens declines, execution cancels the
    /// withdrawal and settles.
    function test_parityWitness_pendingWithdrawalReserved() public {
        deal(address(usdc), address(safe), 100e6);
        _requestUsdcWithdrawal(90e6);

        _assertParity(txId, address(usdc), 100e6);
        assertEq(hitsPendingWithdrawalReserved, 1, "witness must hit the class");
    }

    /// Divergence witness: inside the window the lens previews Credit (no borrowing power for the amount) while
    /// execution settles the same amount as a Debit from the loose balance.
    function test_parityWitness_modeWindowDecline() public {
        deal(address(usdc), address(safe), 100e6);
        _setMode(Mode.Credit);

        _assertParity(txId, address(usdc), 95e6);
        assertEq(hitsModeWindow, 1, "witness must hit the class");
    }

    /// Eventual-parity witness: inside the window the lens approves against the previewed Credit mode; the
    /// Debit execution cannot fund it, and the retry settles once the mode matures.
    function test_parityWitness_modeWindowEventualSettlement() public {
        deal(address(weETH), address(safe), 1 ether);
        _setMode(Mode.Credit);

        _assertParity(txId, address(usdc), 100e6);
        assertTrue(cashModule.transactionCleared(address(safe), txId), "approved auth settled after maturity");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Credit), "retry ran on the matured mode");
    }

    /// Agreement witness: a spend beyond the balance is declined and its execution reverts.
    function test_parityWitness_cleanDecline() public {
        deal(address(usdc), address(safe), 100e6);

        _assertParity(txId, address(usdc), 200e6);
        assertFalse(cashModule.transactionCleared(address(safe), txId), "declined spend must not settle");
    }
}
