// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { CashEventEmitter, CashModuleTestSetup, Mode } from "./CashModuleTestSetup.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CashModuleLiquidationTest is CashModuleTestSetup {
    uint256 collateralAmount = 0.01 ether;
    uint256 collateralValueInUsdc;
    uint256 borrowAmt;

    uint256 HUNDRED_PERCENT = 100e18;

    function setUp() public override {
        super.setUp();

        vm.prank(owner);
        cashModule.setDelays(60, 3600, 0); // set credit mode delay to 0

        _setMode(Mode.Credit);

        collateralValueInUsdc = debtManager.convertCollateralTokenToUsd(address(weETHScroll), collateralAmount);

        deal(address(weETHScroll), address(safe), collateralAmount);
        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), borrowAmt, true);
    }

    function test_liquidation_works() public {
        vm.startPrank(cashOwnerGnosisSafe);

        uint256 liquidatorWeEthBalBefore = weETHScroll.balanceOf(cashOwnerGnosisSafe);

        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = 5e18;
        collateralTokenConfig.liquidationThreshold = 10e18;
        collateralTokenConfig.liquidationBonus = 5e18;

        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);
        assertEq(debtManager.liquidatable(address(safe)), true);

        address[] memory collateralTokenPreference = debtManager.getCollateralTokens();

        deal(address(usdcScroll), cashOwnerGnosisSafe, borrowAmt);
        IERC20(address(usdcScroll)).approve(address(debtManager), borrowAmt);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);

        vm.stopPrank();

        // just to nullify any cashback effect on calculations
        deal(address(scrToken), address(safe), 0);

        uint256 safeCollateralAfter = debtManager.getCollateralValueInUsd(address(safe));
        uint256 safeDebtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        uint256 liquidatorWeEthBalAfter = weETHScroll.balanceOf(cashOwnerGnosisSafe);

        uint256 liquidatedUsdcCollateralAmt = debtManager.convertUsdToCollateralToken(address(weETHScroll), borrowAmt);
        uint256 liquidationBonusReceived = (liquidatedUsdcCollateralAmt * collateralTokenConfig.liquidationBonus) / HUNDRED_PERCENT;
        uint256 liquidationBonusInUsdc = debtManager.convertCollateralTokenToUsd(address(weETHScroll), liquidationBonusReceived);

        assertApproxEqAbs(debtManager.convertCollateralTokenToUsd(address(weETHScroll), liquidatorWeEthBalAfter - liquidatorWeEthBalBefore - liquidationBonusReceived), borrowAmt, 10);
        assertEq(safeDebtAfter, 0);
        assertApproxEqAbs(safeCollateralAfter, collateralValueInUsdc - borrowAmt - liquidationBonusInUsdc, 1);
    }

    function test_liquidation_cancelsPendingWithdrawals() public {
        uint256 withdrawAmt = 0.001 ether;
        deal(address(weETHScroll), address(safe), collateralAmount + withdrawAmt);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weETHScroll);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawAmt;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        vm.startPrank(cashOwnerGnosisSafe);

        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = 5e18;
        collateralTokenConfig.liquidationThreshold = 10e18;
        collateralTokenConfig.liquidationBonus = 5e18;

        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);
        assertEq(debtManager.liquidatable(address(safe)), true);

        address[] memory collateralTokenPreference = debtManager.getCollateralTokens();

        deal(address(usdcScroll), cashOwnerGnosisSafe, borrowAmt);
        IERC20(address(usdcScroll)).approve(address(debtManager), borrowAmt);

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalCancelled(address(safe), tokens, amounts, withdrawRecipient);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);

        vm.stopPrank();

        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(weETHScroll)), 0);
    }
}
