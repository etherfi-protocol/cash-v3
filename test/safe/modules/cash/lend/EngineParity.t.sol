// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { EtherFiSafeErrors } from "../../../../../src/safe/EtherFiSafeErrors.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title EngineParityAaveTest
 * @notice The check side (CashLens.canSpend) and the execution side (CashModule.spend) must agree for every
 *         (mode x engine) cell: an approved check implies the spend lands, and a declined check implies the
 *         spend reverts with the matching error. These are the two on-chain halves of a card auth, so drift
 *         between them declines good taps or, worse, lands taps the check already rejected. The gateway cells run
 *         against a real Aave v4 instance, so the declined-credit revert side (enforced by Aave's borrowing-power
 *         check) is asserted here too; the legacy cells force the DebtManager engine.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/EngineParity.t.sol"
 */
contract EngineParityAaveTest is CashGatewayTestSetup {
    Cashback[] internal noCashback;

    function _canSpend(bytes32 id, address token, uint256 amountUsd) internal view returns (bool, string memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;
        return cashLens.canSpend(address(safe), id, tokens, amounts);
    }

    function _spend(bytes32 id, address token, uint256 amountUsd) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), id, BinSponsor.Reap, tokens, amounts, noCashback);
    }

    // ----------------------------------------------------------------- legacy engine

    /// Legacy debit: an approved balance-limited check lands, a declined one reverts InsufficientBalance.
    function test_parity_legacyDebit_balance() public {
        _forceLegacyEngine(address(safe));
        deal(address(usdc), address(safe), 100e6);

        (bool ok, string memory reason) = _canSpend(keccak256("ld1"), address(usdc), 60e6);
        assertTrue(ok, reason);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        _spend(keccak256("ld1"), address(usdc), 60e6);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 60e6, "approved debit landed");

        (ok, reason) = _canSpend(keccak256("ld2"), address(usdc), 200e6);
        assertFalse(ok);
        assertEq(reason, "Insufficient token balance for debit mode spending");
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        _spend(keccak256("ld2"), address(usdc), 200e6);
    }

    /// Legacy debit: a spend that fits the balance but breaks health is declined and reverts AccountUnhealthy.
    function test_parity_legacyDebit_health() public {
        _forceLegacyEngine(address(safe));
        deal(address(usdc), address(safe), 100e6);
        deal(address(usdc), address(debtManager), 1_000_000e6);

        uint256 borrowAmt = debtManager.getMaxBorrowAmount(address(safe), true) / 2;
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        // The spend fits the balance but would leave the DebtManager position unhealthy
        (bool ok, string memory reason) = _canSpend(keccak256("lh1"), address(usdc), 95e6);
        assertFalse(ok);
        assertEq(reason, "Borrowings greater than max borrow after spending");
        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        _spend(keccak256("lh1"), address(usdc), 95e6);
    }

    /// Legacy credit: an approved borrow lands, and one beyond borrowing power is declined and reverts.
    function test_parity_legacyCredit() public {
        _forceLegacyEngine(address(safe));
        deal(address(weETH), address(safe), 1 ether);
        deal(address(usdc), address(debtManager), 1_000_000e6);
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        (bool ok, string memory reason) = _canSpend(keccak256("lc1"), address(usdc), 100e6);
        assertTrue(ok, reason);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        _spend(keccak256("lc1"), address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 100e6, "approved credit landed");
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdc)), 100e6, 1, "borrowed on the DebtManager");

        // More than the remaining borrowing power (but within the spending limit)
        uint256 tooMuch = debtManager.getMaxBorrowAmount(address(safe), true);
        assertLt(tooMuch, dailyLimitInUsd, "test premise: declined by borrow power, not the limit");
        (ok, reason) = _canSpend(keccak256("lc2"), address(usdc), tooMuch);
        assertFalse(ok);
        assertEq(reason, "Insufficient borrowing power");
        // The DebtManager's AccountUnhealthy surfaces wrapped by the safe's module execution
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.CallFailed.selector, 0));
        _spend(keccak256("lc2"), address(usdc), tooMuch);
    }

    // ----------------------------------------------------------------- gateway engine

    /// LendGateway debit: an approved check withdraws the shortfall from Aave and lands; an over-balance check is declined and reverts.
    function test_parity_gatewayDebit() public {
        // 30 loose + 50 supplied, no debt: loose plus the withdrawable supplied balance cover a 60 spend.
        _supplyToGateway(address(safe), address(usdc), 50e6);
        deal(address(usdc), address(safe), 30e6);

        (bool ok, string memory reason) = _canSpend(keccak256("gd1"), address(usdc), 60e6);
        assertTrue(ok, reason);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 suppliedBefore = gw.suppliedOf(address(safe), address(usdc));
        _spend(keccak256("gd1"), address(usdc), 60e6);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 60e6, "loose plus withdrawn shortfall landed");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), suppliedBefore - 30e6, 2, "shortfall withdrawn from Aave");

        // Nothing loose left and only ~20 supplied: both sides refuse a 100 spend
        (ok, reason) = _canSpend(keccak256("gd2"), address(usdc), 100e6);
        assertFalse(ok);
        assertEq(reason, "Insufficient token balance for debit mode spending");
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        _spend(keccak256("gd2"), address(usdc), 100e6);
    }

    /// LendGateway credit: an approved check borrows on Aave and lands; one beyond borrow power (with nothing to resupply) is declined and reverts.
    function test_parity_gatewayCredit() public {
        _supplyToGateway(address(safe), address(usdc), 1000e6); // ~$800 borrowing power at 80%, nothing loose
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        (bool ok, string memory reason) = _canSpend(keccak256("gc1"), address(usdc), 100e6);
        assertTrue(ok, reason);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        _spend(keccak256("gc1"), address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 100e6, "approved credit borrowed and landed");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 100e6, 2, "borrowed on the gateway");

        // Beyond the remaining borrowing power, with no loose collateral to resupply: declined and the borrow reverts.
        uint256 tooMuch = gw.getAccountData(address(safe)).availableBorrowsUsd + 100e6;
        (ok, reason) = _canSpend(keccak256("gc2"), address(usdc), tooMuch);
        assertFalse(ok);
        assertEq(reason, "Insufficient borrowing power");
        vm.expectRevert(ISpoke.HealthFactorBelowThreshold.selector);
        _spend(keccak256("gc2"), address(usdc), tooMuch);
    }
}
