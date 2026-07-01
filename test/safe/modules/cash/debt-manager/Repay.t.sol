// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CashEventEmitter, CashModuleTestSetup, IERC20, IDebtManager, ICashModule, Mode } from "../CashModuleTestSetup.t.sol";
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";

/// @notice Repay now routes to the Aave gateway (repay onBehalf) instead of DebtManager. These tests
///         assert the gateway call and the CashModule-level guards; debt accounting (interest, partial,
///         cap-at-debt, capacity) is Aave's behavior and is covered by the gateway ops tests.
contract DebtManagerRepayTest is CashModuleTestSetup {
    uint256 amountInUsd = 100e6;
    uint256 expectedAmount;

    function setUp() public override {
        super.setUp();
        expectedAmount = debtManager.convertUsdToCollateralToken(address(usdc), amountInUsd);
    }

    function test_repay_callsGatewayRepay() public {
        deal(address(usdc), address(safe), expectedAmount);

        vm.startPrank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.RepayDebtManager(address(safe), address(usdc), expectedAmount, amountInUsd);
        cashModule.repay(address(safe), address(usdc), amountInUsd);
        vm.stopPrank();

        (address s, address asset, uint256 amt, address to) = gateway.lastRepay();
        assertEq(s, address(safe));
        assertEq(asset, address(usdc));
        assertEq(amt, expectedAmount);
        assertEq(to, address(0));
    }

    function test_repay_fails_withNonBorrowToken() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyBorrowToken.selector);
        cashModule.repay(address(safe), address(weETH), 1 ether);
    }

    function test_repay_fails_nonEtherFiSafe() public {
        // onlyEtherFiSafe reverts OnlyEtherFiSafe(); the selector is shared across contracts declaring it
        vm.prank(etherFiWallet);
        vm.expectRevert(IDebtManager.OnlyEtherFiSafe.selector);
        cashModule.repay(makeAddr("notSafe"), address(usdc), amountInUsd);
    }

    function test_repay_fails_whenAmountIsZero() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.AmountZero.selector);
        cashModule.repay(address(safe), address(usdc), 0);
    }

    function test_repay_fails_whenBalanceIsInsufficient() public {
        deal(address(usdc), address(safe), 0);

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.repay(address(safe), address(usdc), amountInUsd);
    }
}
