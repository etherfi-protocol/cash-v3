// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, Cashback, ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title CashModuleMultiSpendAaveTest
 * @notice The gateway-path multi-token debit spends that read a real Aave position: sourcing a token partly from
 *         its loose balance and partly from its Aave-supplied balance under debt, and the shared borrowing
 *         headroom binding across tokens. The loose-only multi-token spends (proportions, cashback, limits,
 *         pending) that never read a gateway position stay in test/safe/modules/cash/MultiSpend.t.sol.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/MultiSpend.t.sol"
 */
contract CashModuleMultiSpendAaveTest is CashGatewayTestSetup {
    /// @dev weETH is a spendable (borrowable) token in these multi-token tests.
    function _weethBorrowable() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        // These tests debit-spend weETH, so declare it a spend asset (membership is no longer the borrowable flag)
        vm.prank(owner);
        gw.setSpendAsset(address(weETH), true);
    }

    /// A two-token debit under debt: USDC fully from the loose balance, weETH from a loose + Aave-supplied mix.
    function test_spend_multiToken_mixedLooseAndSupplied_withDebt() public {
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), 50e6); // fully from the loose balance
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), 40e6); // part loose, part from Aave
        uint256 weETHLoose = debtManager.convertUsdToCollateralToken(address(weETH), 10e6);

        // weETH carries ample borrowing power, so a small USDC debt leaves the weETH withdrawal well within headroom.
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        _borrowOnGateway(address(safe), address(usdc), 100e6, recipient);
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHLoose);

        uint256 suppliedWeethBefore = gw.suppliedOf(address(safe), address(weETH));
        uint256 dispatcherUsdcBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 dispatcherWeethBefore = weETH.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = 50e6;
        spendAmounts[1] = 40e6;

        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Both loose balances drain to the dispatcher; weETH's shortfall is withdrawn from Aave.
        assertEq(usdc.balanceOf(address(safe)), 0, "loose USDC spent");
        assertEq(weETH.balanceOf(address(safe)), 0, "loose weETH spent");
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherUsdcBefore + usdcAmount, "USDC routed to dispatcher");
        assertEq(weETH.balanceOf(address(settlementDispatcherReap)), dispatcherWeethBefore + weETHAmount, "full weETH routed to dispatcher");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), suppliedWeethBefore - (weETHAmount - weETHLoose), 2, "weETH shortfall withdrawn from Aave");
    }

    /// With debt, the borrowing headroom is shared across the debit: USDC's Aave draw consumes it first, so weETH's draw reverts.
    function test_spend_multiToken_revertsWhenSuppliedDrawsExceedSharedHeadroom_withDebt() public {
        // 100 USDC + $100 weETH supplied at 80%, 120 borrowed: $40 headroom funds $50 of withdrawals. USDC's $30 draw
        // spends $24 of it, leaving room for only $20 of weETH, short of its $30 draw.
        _supplyToGateway(address(safe), address(usdc), 100e6);
        _supplyToGateway(address(safe), address(weETH), debtManager.convertUsdToCollateralToken(address(weETH), 100e6));
        _borrowOnGateway(address(safe), address(usdc), 120e6, recipient);
        deal(address(usdc), address(safe), 0);
        deal(address(weETH), address(safe), 0);

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = 30e6;
        spendAmounts[1] = 30e6;

        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }
}
