// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode, SafeCashData } from "../../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title CashLensAaveTest
 * @notice The gateway-path CashLens reads (collateral, safe cash data with and without borrows) built through
 *         real Aave supply/borrow flows. The legacy-engine and plumbing CashLens tests stay in
 *         test/safe/modules/cash/CashLens.t.sol (default profile).
 * @dev Run with: source .env && FOUNDRY_PROFILE=aave TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/aave/CashLens.t.sol"
 */
contract CashLensAaveTest is CashGatewayTestSetup {
    /// A gateway safe's collateral is its Aave-supplied balance; loose funds don't count.
    function test_getUserCollateralForToken_gatewaySafe_readsSuppliedBalance() public {
        deal(address(weETH), address(safe), 5 ether); // loose, not collateral for a gateway safe
        assertEq(cashLens.getUserCollateralForToken(address(safe), address(weETH)), 0, "loose balance is not collateral");

        _supplyToGateway(address(safe), address(weETH), 3 ether);
        assertApproxEqAbs(cashLens.getUserCollateralForToken(address(safe), address(weETH)), 3 ether, 2, "supplied balance is the collateral");

        IDebtManager.TokenData[] memory collateral = cashLens.getUserTotalCollateral(address(safe));
        assertEq(collateral.length, 1, "only the supplied token shows up");
        assertEq(collateral[0].token, address(weETH));
        assertApproxEqAbs(collateral[0].amount, 3 ether, 2);
    }

    /// getSafeCashData reports collateral entries, debit mode, and a pending withdrawal for a gateway safe with no borrows.
    function test_getSafeCashData() public {
        // 5 weETH + 5000 USDC supplied as collateral; 5000 USDC loose with a pending withdrawal against it.
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _supplyToGateway(address(safe), address(usdc), 5000e6);
        deal(address(usdc), address(safe), 5000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), new address[](0));

        assertEq(uint8(data.mode), uint8(Mode.Debit), "Initial mode should be Debit");
        assertEq(data.incomingModeStartTime, 0, "No incoming mode change");
        assertEq(data.totalCashbackEarnedInUsd, 0, "No cashback earned initially");

        assertEq(data.collateralBalances.length, 2, "Should have two collateral entries");
        assertEq(data.borrows.length, 0, "Should have no borrows initially");

        assertEq(data.withdrawalRequest.tokens.length, 1, "Should have one withdrawal token");
        assertEq(data.withdrawalRequest.amounts.length, 1, "Should have one withdrawal amount");
        assertEq(data.withdrawalRequest.tokens[0], address(usdc), "Withdrawal token should be USDC");
        assertEq(data.withdrawalRequest.amounts[0], 5000e6, "Withdrawal amount should be 5000 USDC");

        // Totals come straight from the gateway's account data, the same source CashLens reads.
        ILendGateway.AccountData memory account = gw.getAccountData(address(safe));
        assertEq(data.totalCollateral, account.collateralUsd, "Total collateral matches gateway");
        assertEq(data.totalBorrow, 0, "Total borrow should be zero initially");
        assertEq(data.maxBorrow, account.availableBorrowsUsd + account.debtUsd, "Max borrow matches gateway headroom plus debt");
    }

    /// getSafeCashData reports the outstanding Aave debt as the safe's borrow.
    function test_getSafeCashData_withBorrows() public {
        uint256 borrowAmount = 1000e6;
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), borrowAmount);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), new address[](0));

        assertEq(data.borrows.length, 1, "Should have one borrow entry");
        assertEq(data.borrows[0].token, address(usdc), "Borrow token should be USDC");
        assertApproxEqAbs(data.borrows[0].amount, borrowAmount, 2, "Borrow amount should match the Aave debt");
        assertApproxEqAbs(data.totalBorrow, borrowAmount, 2, "Total borrow should match the Aave debt");
    }
}
