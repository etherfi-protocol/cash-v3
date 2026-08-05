// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Mode, WithdrawalRequest } from "../../../../../src/interfaces/ICashModule.sol";
import { IPriceProvider } from "../../../../../src/interfaces/IPriceProvider.sol";
import { LendSourcingLib } from "../../../../../src/libraries/LendSourcingLib.sol";
import { SafeTestSetup } from "../../../SafeTestSetup.t.sol";
import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { ParityFuzzBase } from "../helpers/ParityFuzzBase.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title EngineParityFuzzAaveTest
 * @notice canSpend/spend parity fuzz for gateway safes against a real Aave v4 instance: an approved check
 *         settles (eventually, inside a pending-mode window), and a declined-but-settled spend must be a
 *         known conservative asymmetry: the min-health-factor buffer vs Aave's raw bound, the cancelled
 *         pending withdrawal, spend-time resupply of loose collateral, or the mode window. Amounts anchor
 *         to the lens quotes so runs cluster around the approve/decline boundary.
 * @dev A min-health-factor floor is set so the buffered-vs-raw class is reachable. Deterministic witnesses
 *      prove each class fires; the debit-side buffered-floor class shares its mechanism with the credit
 *      witness and is left to the fuzz.
 *      Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/EngineParityFuzz.t.sol"
 */
contract EngineParityFuzzAaveTest is ParityFuzzBase, CashGatewayTestSetup {
    uint256 internal constant FLOOR = 1.05e18;

    /// Sets a health-factor floor on top of the gateway setup so the buffered-vs-raw divergence class
    /// is reachable during the fuzz.
    function setUp() public override(CashModuleTestSetup, CashGatewayTestSetup) {
        super.setUp();
        vm.prank(owner);
        gw.setMinHealthFactor(FLOOR);
    }

    // Diamond re-overrides (ParityFuzzBase and CashGatewayTestSetup share CashModuleTestSetup); both
    // resolve to the gateway setup's versions.
    function _wireDefaultGateway() internal override(SafeTestSetup, CashGatewayTestSetup) {
        super._wireDefaultGateway();
    }

    /// Keeps the gateway setup's onboarding choice (the safe onboards legacy, then flips to the gateway).
    function _newSafeUsesLend() internal pure override(CashModuleTestSetup, CashGatewayTestSetup) returns (bool) {
        return super._newSafeUsesLend();
    }

    /// Gateway divergence predicates, evaluated pre-spend against the mode execution will run.
    function _classify(address token, uint256 amountUsd) internal view override returns (Divergence) {
        IPriceProvider pp = IPriceProvider(address(priceProvider));
        if (cashModule.getMode(address(safe)) == Mode.Credit) {
            uint256 needed = LendSourcingLib.fromUsdUp(pp, token, amountUsd);
            if (gw.borrowCapacity(address(safe), token) < needed && needed <= gw.rawBorrowCapacity(address(safe), token)) {
                return Divergence.BufferedFloor;
            }
            if (weETH.balanceOf(address(safe)) > 0 || usdc.balanceOf(address(safe)) > 0) {
                return Divergence.ResupplyInvisible;
            }
        } else {
            uint256 needed = LendSourcingLib.fromUsd(pp, token, amountUsd);
            uint256 loose = IERC20(token).balanceOf(address(safe));
            uint256 pending = _pendingOf(token);
            uint256 looseNet = loose > pending ? loose - pending : 0;
            bool hasDebt = gw.hasDebt(address(safe));
            if (hasDebt) {
                uint256 buffered = LendSourcingLib.withdrawableSupplied(gw, address(safe), token, gw.withdrawHeadroom(address(safe)), true);
                uint256 raw = LendSourcingLib.withdrawableSupplied(gw, address(safe), token, gw.rawWithdrawHeadroom(address(safe)), true);
                if (looseNet + buffered < needed && looseNet + raw >= needed) {
                    return Divergence.BufferedFloor;
                }
            }
        }
        return Divergence.Unexplained;
    }

    /// Amount of `token` reserved by the safe's pending withdrawal request, or 0 if none holds it.
    function _pendingOf(address token) private view returns (uint256) {
        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        for (uint256 i = 0; i < request.tokens.length; i++) {
            if (request.tokens[i] == token) {
                return request.amounts[i];
            }
        }
        return 0;
    }

    /// Single-element token array holding USDC, the spend token of every run.
    function _usdcArray() private view returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        return tokens;
    }

    /// Places a pending withdrawal request of `amount` of `token`, reserving it from the loose balance.
    function _requestTokenWithdrawal(address token, uint256 amount) private {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
    }

    /// Debit parity across fuzzed loose/supplied splits, debt, reservations (including one outgrowing
    /// the balance), accrual, and a pending Credit switch: the lens verdict must predict the spend
    /// outcome per the parity properties.
    /// forge-config: lend.fuzz.runs = 64
    function testFuzz_parity_gatewayDebit(uint256 suppliedUsdc, uint256 looseUsdc, uint256 collateralWeeth, uint256 debtBps, uint256 withdrawalBpsOfLoose, bool drainBalanceBelowReservation, uint256 spendBpsOfQuote, bool creditPending, uint256 warpSecs) public {
        suppliedUsdc = bound(suppliedUsdc, 10e6, 2000e6);
        looseUsdc = bound(looseUsdc, 0, 1000e6);
        collateralWeeth = bound(collateralWeeth, 0, 1 ether);
        debtBps = bound(debtBps, 0, 7000);
        withdrawalBpsOfLoose = bound(withdrawalBpsOfLoose, 0, 10_000);
        spendBpsOfQuote = bound(spendBpsOfQuote, 1, 13_000);
        warpSecs = bound(warpSecs, 0, 30 minutes);

        _supplyToGateway(address(safe), address(usdc), suppliedUsdc);
        if (collateralWeeth >= 0.05 ether) {
            _supplyToGateway(address(safe), address(weETH), collateralWeeth);
            uint256 debtAmt = (gw.borrowCapacity(address(safe), address(usdc)) * debtBps) / 10_000;
            if (debtAmt > 0) {
                _borrowOnGateway(address(safe), address(usdc), debtAmt, recipient);
            }
        }
        deal(address(usdc), address(safe), looseUsdc);
        uint256 reservation = (looseUsdc * withdrawalBpsOfLoose) / 10_000;
        if (reservation > 0) {
            _requestTokenWithdrawal(address(usdc), reservation);
            if (drainBalanceBelowReservation) {
                // Funds moved after the request, leaving the reservation larger than the balance by one
                // unit: the tightest form of the state whose unguarded subtraction used to underflow
                deal(address(usdc), address(safe), reservation - 1);
            }
        }
        if (warpSecs > 0) {
            vm.warp(block.timestamp + warpSecs);
        }
        if (creditPending) {
            _setMode(Mode.Credit);
        }

        uint256 quote = cashLens.getMaxSpendDebit(address(safe), _usdcArray()).totalSpendableInUsd;
        uint256 amountUsd = (quote * spendBpsOfQuote) / 10_000;
        if (amountUsd == 0) {
            amountUsd = 1;
        }

        _assertParity(txId, address(usdc), amountUsd);
    }

    /// Credit parity across fuzzed collateral, loose (resupplyable) balances, prior debt, reservations,
    /// accrual, and both sides of the mode-delay boundary: the lens verdict must predict the spend
    /// outcome per the parity properties.
    /// forge-config: lend.fuzz.runs = 64
    function testFuzz_parity_gatewayCredit(uint256 collateralWeeth, uint256 looseWeeth, uint256 priorDebtBps, uint256 withdrawalBpsOfLooseWeeth, uint256 spendBpsOfQuote, bool matured, uint256 warpSecs) public {
        collateralWeeth = bound(collateralWeeth, 0.05 ether, 1 ether);
        looseWeeth = bound(looseWeeth, 0, 0.5 ether);
        priorDebtBps = bound(priorDebtBps, 0, 6000);
        withdrawalBpsOfLooseWeeth = bound(withdrawalBpsOfLooseWeeth, 0, 10_000);
        spendBpsOfQuote = bound(spendBpsOfQuote, 1, 13_000);
        warpSecs = bound(warpSecs, 0, 30 minutes);

        _supplyToGateway(address(safe), address(weETH), collateralWeeth);
        uint256 debtAmt = (gw.borrowCapacity(address(safe), address(usdc)) * priorDebtBps) / 10_000;
        if (debtAmt > 0) {
            _borrowOnGateway(address(safe), address(usdc), debtAmt, recipient);
        }
        deal(address(weETH), address(safe), looseWeeth);
        uint256 weethReservation = (looseWeeth * withdrawalBpsOfLooseWeeth) / 10_000;
        if (weethReservation > 0) {
            _requestTokenWithdrawal(address(weETH), weethReservation);
        }
        if (warpSecs > 0) {
            vm.warp(block.timestamp + warpSecs);
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

        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(weETH));
        uint256 resupplyHitsBefore = hitsResupplyInvisible;
        _assertParity(txId, address(usdc), amountUsd);

        // The resupply predicate only says loose collateral existed, so make the class prove itself:
        // a spend excused by resupply must actually have moved that collateral into Aave.
        if (hitsResupplyInvisible > resupplyHitsBefore) {
            assertGt(gw.suppliedOf(address(safe), address(weETH)), suppliedBefore, "resupply-excused spend did not resupply");
        }
    }

    // ----------------------------------------------------------------- deterministic witnesses

    /// Divergence witness: the amount fits Aave's raw bound but not the floor-buffered quote; the lens declines,
    /// execution settles against the raw bound.
    function test_parityWitness_bufferedFloor() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        IPriceProvider pp = IPriceProvider(address(priceProvider));
        uint256 bufferedUsd = LendSourcingLib.toUsd(pp, address(usdc), gw.borrowCapacity(address(safe), address(usdc)));
        uint256 rawUsd = LendSourcingLib.toUsd(pp, address(usdc), gw.rawBorrowCapacity(address(safe), address(usdc)));
        assertGt(rawUsd, bufferedUsd, "premise: the floor buffers the quote");

        _assertParity(txId, address(usdc), (bufferedUsd + rawUsd) / 2);
        assertEq(hitsBufferedFloor, 1, "witness must hit the class");
    }

    /// Divergence witness: loose collateral the lens ignores lets the spend-time resupply fit the borrow.
    function test_parityWitness_resupplyInvisible() public {
        _supplyToGateway(address(safe), address(weETH), 0.5 ether);
        deal(address(weETH), address(safe), 0.5 ether);
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(weETH));
        // Fits only once the loose half is resupplied: beyond raw capacity, inside the doubled collateral
        uint256 amountUsd = (cashLens.getMaxSpendCredit(address(safe)) * 15_000) / 10_000;

        _assertParity(txId, address(usdc), amountUsd);
        assertEq(hitsResupplyInvisible, 1, "witness must hit the class");
        assertGt(gw.suppliedOf(address(safe), address(weETH)), suppliedBefore, "the spend resupplied the loose collateral");
    }

    /// Divergence witness: the spend needs the reserved loose balance; the lens declines, execution cancels the
    /// withdrawal and settles.
    function test_parityWitness_pendingWithdrawalReserved() public {
        deal(address(usdc), address(safe), 100e6);
        _requestTokenWithdrawal(address(usdc), 90e6);

        _assertParity(txId, address(usdc), 100e6);
        assertEq(hitsPendingWithdrawalReserved, 1, "witness must hit the class");
    }

    /// Eventual-parity witness: the lens approves against the previewed Credit mode, the Debit execution
    /// cannot fund it, and the retry settles once the mode matures.
    function test_parityWitness_modeWindowEventualSettlement() public {
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        _setMode(Mode.Credit);

        _assertParity(txId, address(usdc), 100e6);
        assertTrue(cashModule.transactionCleared(address(safe), txId), "approved auth settled after maturity");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Credit), "retry ran on the matured mode");
    }

    /// Agreement witness: a credit spend beyond even the raw capacity with nothing to resupply is
    /// declined and its execution reverts.
    function test_parityWitness_cleanDecline() public {
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        _assertParity(txId, address(usdc), 500e6);
        assertFalse(cashModule.transactionCleared(address(safe), txId), "declined spend must not settle");
    }
}
