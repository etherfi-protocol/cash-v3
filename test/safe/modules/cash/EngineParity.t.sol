// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { ILendGateway } from "../../../../src/interfaces/ILendGateway.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

/**
 * @title EngineParityTest
 * @notice The check side (CashLens.canSpend) and the execution side (CashModule.spend) must agree for every
 *         (mode x engine) cell: an approved check implies the spend lands, and a declined check implies the
 *         spend reverts with the matching error. These are the two on-chain halves of a card auth, so drift
 *         between them declines good taps or, worse, lands taps the check already rejected.
 * @dev LendGateway-credit declined-side parity (borrow power) is enforced by Aave itself, which the mock gateway
 *      cannot model; it runs in the fork suite (test/lend-gateway/DebtManagerMigration.t.sol) instead.
 */
contract EngineParityTest is CashModuleTestSetup {
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

    /// LendGateway debit: an approved check withdraws the shortfall from Aave and lands; an over-balance check reverts.
    function test_parity_gatewayDebit() public {
        deal(address(usdc), address(safe), 30e6);
        gateway.setSuppliedOf(address(safe), address(usdc), 50e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setAccountData(address(safe), ILendGateway.AccountData({ collateralUsd: 50e6, debtUsd: 0, availableBorrowsUsd: 40e6, healthFactor: type(uint256).max }));

        // Loose (30) + supplied (50) cover the spend; the shortfall is withdrawn from Aave
        (bool ok, string memory reason) = _canSpend(keccak256("gd1"), address(usdc), 60e6);
        assertTrue(ok, reason);
        uint256 dispatcherBefore = usdc.balanceOf(address(settlementDispatcherReap));
        _spend(keccak256("gd1"), address(usdc), 60e6);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBefore + 30e6, "loose portion transferred");
        (, address asset, uint256 amount, address to) = gateway.lastWithdraw();
        assertEq(asset, address(usdc));
        assertEq(amount, 30e6, "shortfall withdrawn from Aave");
        assertEq(to, address(settlementDispatcherReap));

        // Nothing loose left and only 50 supplied: both sides refuse a 100 spend
        (ok, reason) = _canSpend(keccak256("gd2"), address(usdc), 100e6);
        assertFalse(ok);
        assertEq(reason, "Insufficient token balance for debit mode spending");
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        _spend(keccak256("gd2"), address(usdc), 100e6);
    }

    /// LendGateway credit: an approved check borrows on the gateway and lands; one beyond borrow power is declined.
    function test_parity_gatewayCredit_approvedLands() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setAccountData(address(safe), ILendGateway.AccountData({ collateralUsd: 1000e6, debtUsd: 0, availableBorrowsUsd: 500e6, healthFactor: type(uint256).max }));

        (bool ok, string memory reason) = _canSpend(keccak256("gc1"), address(usdc), 100e6);
        assertTrue(ok, reason);
        _spend(keccak256("gc1"), address(usdc), 100e6);
        (, address asset, uint256 amount, address to) = gateway.lastBorrow();
        assertEq(asset, address(usdc));
        assertEq(amount, 100e6, "approved credit borrowed on the gateway");
        assertEq(to, address(settlementDispatcherReap));

        // Beyond the Aave borrowing power: declined by the check (the revert side is enforced by Aave and
        // covered in the fork suite)
        (ok, reason) = _canSpend(keccak256("gc2"), address(usdc), 600e6);
        assertFalse(ok);
        assertEq(reason, "Insufficient borrowing power");
    }
}
