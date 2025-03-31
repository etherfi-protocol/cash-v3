// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { CashEventEmitter, CashModuleTestSetup, Mode } from "../CashModuleTestSetup.t.sol";
import { PriceProvider } from "../../../../../src/oracle/PriceProvider.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";

contract DebtManagerLiquidationTest is CashModuleTestSetup {
    uint256 collateralAmount = 0.01 ether;
    uint256 collateralValueInUsdc;
    uint256 borrowAmt;
    uint256 mockWeETHPriceInUsd = 3000e6;

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

    function test_setCollateralTokenConfig_updatesLiquidationThreshold_whenCalledByAdmin() public {     
        uint80 newThreshold = 70e18;

        IDebtManager.CollateralTokenConfig memory collateralTokenConfig = debtManager.collateralTokenConfig(address(weETHScroll));
        collateralTokenConfig.liquidationThreshold = newThreshold;

        vm.prank(owner);
        debtManager.setCollateralTokenConfig(
            address(weETHScroll),
            collateralTokenConfig
        );

        IDebtManager.CollateralTokenConfig memory configFromContract = debtManager.collateralTokenConfig(address(weETHScroll));
        assertEq(configFromContract.liquidationThreshold, newThreshold);
    }

    function test_setCollateralTokenConfig_reverts_whenCallerNotAdmin() public {
        uint80 newThreshold = 70e18;
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig = debtManager.collateralTokenConfig(address(weETHScroll));
        collateralTokenConfig.liquidationThreshold = newThreshold;

        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);

        vm.stopPrank();
    }

    function test_liquidate_succeeds_whenPositionLiquidatable() public {
        vm.startPrank(owner);

        uint256 liquidatorWeEthBalBefore = weETHScroll.balanceOf(owner);

        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = 5e18;
        collateralTokenConfig.liquidationThreshold = 10e18;
        collateralTokenConfig.liquidationBonus = 5e18;

        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);
        assertEq(debtManager.liquidatable(address(safe)), true);

        address[] memory collateralTokenPreference = debtManager.getCollateralTokens();

        deal(address(usdcScroll), owner, borrowAmt);
        IERC20(address(usdcScroll)).approve(address(debtManager), borrowAmt);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);

        vm.stopPrank();

        // just to nullify any cashback effect on calculations
        deal(address(scrToken), address(safe), 0);

        uint256 safeCollateralAfter = debtManager.getCollateralValueInUsd(address(safe));
        uint256 safeDebtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        uint256 liquidatorWeEthBalAfter = weETHScroll.balanceOf(owner);

        uint256 liquidatedUsdcCollateralAmt = debtManager.convertUsdToCollateralToken(address(weETHScroll), borrowAmt);
        uint256 liquidationBonusReceived = (liquidatedUsdcCollateralAmt * collateralTokenConfig.liquidationBonus) / HUNDRED_PERCENT;
        uint256 liquidationBonusInUsdc = debtManager.convertCollateralTokenToUsd(address(weETHScroll), liquidationBonusReceived);

        assertApproxEqAbs(debtManager.convertCollateralTokenToUsd(address(weETHScroll), liquidatorWeEthBalAfter - liquidatorWeEthBalBefore - liquidationBonusReceived), borrowAmt, 10);
        assertEq(safeDebtAfter, 0);
        assertApproxEqAbs(safeCollateralAfter, collateralValueInUsdc - borrowAmt - liquidationBonusInUsdc, 1);
    }

    function test_liquidate_cancelsPendingWithdrawals_whenWithdrawalsExist() public {
        uint256 withdrawAmt = 0.001 ether;
        deal(address(weETHScroll), address(safe), collateralAmount + withdrawAmt);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weETHScroll);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawAmt;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        vm.startPrank(owner);

        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = 5e18;
        collateralTokenConfig.liquidationThreshold = 10e18;
        collateralTokenConfig.liquidationBonus = 5e18;

        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);
        assertEq(debtManager.liquidatable(address(safe)), true);

        address[] memory collateralTokenPreference = debtManager.getCollateralTokens();

        deal(address(usdcScroll), owner, borrowAmt);
        IERC20(address(usdcScroll)).approve(address(debtManager), borrowAmt);

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalCancelled(address(safe), tokens, amounts, withdrawRecipient);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);

        vm.stopPrank();

        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(weETHScroll)), 0);
    }

    function test_liquidate_reverts_whenPositionNotLiquidatable() public {
        vm.startPrank(owner);
        assertEq(debtManager.liquidatable(address(safe)), false);
        IERC20(address(usdcScroll)).approve(address(debtManager), borrowAmt);

        address[] memory collateralTokens = debtManager.getCollateralTokens();
        vm.expectRevert(IDebtManager.CannotLiquidateYet.selector);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokens);

        vm.stopPrank();
    }

    function test_liquidate_reverts_whenInvalidCollateralTokensProvided() public {
        deal(address(usdcScroll), address(safe), borrowAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), borrowAmt);

        priceProvider = PriceProvider(
            address(new MockPriceProvider(mockWeETHPriceInUsd, address(usdcScroll)))
        );
        vm.prank(owner);
        dataProvider.setPriceProvider(address(priceProvider));

        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        // safe should borrow at new price for our calculations to be correct
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), borrowAmt, false);

        vm.startPrank(owner);
        uint256 newPrice = 1000e6; // 1000 USD per weETH
        MockPriceProvider(address(priceProvider)).setPrice(newPrice);
        
        // Lower the thresholds for weETH as well
        IDebtManager.CollateralTokenConfig memory collateralTokenConfigWeETH;
        collateralTokenConfigWeETH.ltv = 5e18;
        collateralTokenConfigWeETH.liquidationThreshold = 10e18;
        collateralTokenConfigWeETH.liquidationBonus = 5e18;
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfigWeETH);

        address mockToken = address(new MockERC20("mockToken", "mock", 18));
        address[] memory collateralTokenPreference = new address[](2);
        collateralTokenPreference[0] = address(mockToken);
        collateralTokenPreference[1] = address(weETHScroll);

        uint256 liquidationAmt = 5e6;

        IERC20(address(usdcScroll)).approve(address(debtManager), liquidationAmt);
        vm.expectRevert(IDebtManager.NotACollateralToken.selector);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);

        vm.stopPrank();
    }

    function test_liquidate_chargesCorrectAmount_whenPositionLiquidated() public {
        deal(address(usdcScroll), address(safe), borrowAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), borrowAmt);

        priceProvider = PriceProvider(
            address(new MockPriceProvider(mockWeETHPriceInUsd, address(usdcScroll)))
        );
        vm.prank(owner);
        dataProvider.setPriceProvider(address(priceProvider));

        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        // safe should borrow at new price for our calculations to be correct
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), borrowAmt, false);

        vm.startPrank(owner);
        uint256 newPrice = 1000e6; // 1000 USD per weETH
        MockPriceProvider(address(priceProvider)).setPrice(newPrice);
        
        // Lower the thresholds for weETH as well
        IDebtManager.CollateralTokenConfig memory collateralTokenConfigWeETH;
        collateralTokenConfigWeETH.ltv = 5e18;
        collateralTokenConfigWeETH.liquidationThreshold = 10e18;
        collateralTokenConfigWeETH.liquidationBonus = 5e18;
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfigWeETH);

        // Now price of collateral token is 1000 USD per weETH
        // total collateral = 0.01 weETH => 10 USD
        // total debt = based on price 3000 USD per weETH and 50% LTV -> 15 USD
        // So total collateral < total debt
        // Also the user is liquidatable since liquidation threshold is 10% 
        
        // 50% liquidation -> 
        // Debt is 15 USD -> 7.5 USD to liquidate first
        // weETH amt -> 7.5 / 1000 = 0.0075 weETH
        // bonus -> 5% -> 0.0075 * 5% = 0.000375 weETH
        // total collateral gone -> 0.007875

        // next 50% liquidation (since user is still liquidatable)
        // collateral left -> 0.002125 weETH
        // total value in USD -> 0.002125 * 1000 -> 2.125 USD
        // total bonus -> 0.002125 * 5% = 0.00010625 weETH -> 0.10625 USD
        // total collateral liquidated -> 2.125 - 0.10625 USD -> 2.01875 USD

        // total liquidated amount -> 7.5 + 2.01875 USD = 9.51875 USD

        uint256 liquidationAmt = 9.51875 * 1e6;

        address[] memory collateralTokenPreference = new address[](1);
        collateralTokenPreference[0] = address(weETHScroll);

        uint256 ownerWeETHBalBefore = weETHScroll.balanceOf(owner);
        uint256 ownerUsdcBalBefore = IERC20(address(usdcScroll)).balanceOf(owner);
        uint256 aliceSafeDebtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));
        uint256 aliceSafeCollateralBefore = debtManager.getCollateralValueInUsd(address(safe));

        IERC20(address(usdcScroll)).approve(address(debtManager), liquidationAmt);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);

        uint256 ownerWeETHBalAfter = weETHScroll.balanceOf(owner);
        uint256 ownerUsdcBalAfter = IERC20(address(usdcScroll)).balanceOf(owner);
        uint256 aliceSafeDebtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));
        uint256 aliceSafeCollateralAfter = debtManager.getCollateralValueInUsd(address(safe));

        assertEq(ownerWeETHBalAfter - ownerWeETHBalBefore, collateralAmount);
        assertEq(ownerUsdcBalBefore - ownerUsdcBalAfter, liquidationAmt);
        assertEq(aliceSafeDebtBefore, borrowAmt);
        assertEq(aliceSafeDebtAfter, borrowAmt - liquidationAmt);
        assertEq(aliceSafeCollateralBefore, 10e6); // price dropped to 1000 USD and 0.01 weETH was collateral
        assertEq(aliceSafeCollateralAfter, 0);

        vm.stopPrank();
    }

    function test_liquidate_respectsCollateralPreference_whenMultipleCollateralsAvailable() public {
        deal(address(usdcScroll), address(safe), borrowAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), borrowAmt);
                
        priceProvider = PriceProvider(
            address(new MockPriceProvider(mockWeETHPriceInUsd, address(usdcScroll)))
        );
        vm.prank(owner);
        dataProvider.setPriceProvider(address(priceProvider));

        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        // Alice should borrow at new price for our calculations to be correct
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), borrowAmt, false);
        
        address newCollateralToken = address(new MockERC20("collateral", "CTK", 18));
        IDebtManager.CollateralTokenConfig memory collateralTokenConfigNewCollateralToken;
        collateralTokenConfigNewCollateralToken.ltv = 5e18;
        collateralTokenConfigNewCollateralToken.liquidationThreshold = 10e18;
        collateralTokenConfigNewCollateralToken.liquidationBonus = 10e18;

        vm.startPrank(owner);
        debtManager.supportCollateralToken(
            newCollateralToken,
            collateralTokenConfigNewCollateralToken
        );

        uint256 collateralAmtNewToken = 0.005 ether;
        deal(newCollateralToken, address(safe), collateralAmtNewToken);

        // Lower the thresholds for weETH as well
        IDebtManager.CollateralTokenConfig memory collateralTokenConfigWeETH;
        collateralTokenConfigWeETH.ltv = 5e18;
        collateralTokenConfigWeETH.liquidationThreshold = 10e18;
        collateralTokenConfigWeETH.liquidationBonus = 5e18;
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfigWeETH);

        address[] memory collateralTokenPreference = new address[](2);
        collateralTokenPreference[0] = newCollateralToken;
        collateralTokenPreference[1] = address(weETHScroll);

        assertEq(debtManager.liquidatable(address(safe)), true);

        // currently, alice collateral -> 
        // 0.01 weETH + 0.005 newToken  => 30 + 15 = 45 USDC (since 3000 is the default price in mock price provider)
        // alice debt -> 30 * 50% = 15 USD (initial collateral 30 USD, LTV: 50%)
        // When we liquidate -> user should receive the following:
        
        // for a debt of 15 USD ->

        // first liquidate 50% loan -> 7.5 USD

        // new token is first in preference 
        // total collateral in new token -> 0.005 * 3000 = 15 USDC
        // debt amount in new collateral token -> 7.5 USD / 3000 USD = 0.0025 
        // liquidation bonus -> 0.0025 * 10% bonus -> 0.00025 in collateral tokens -> 0.75 USDC 
        // Collateral left in new token = 0.005 - 0.0025 - 0.00025 = 0.00225
        
        // After partial liquidation -> 
        // user debt -> 7.5 USDC
        // user collateral -> 0.01 weETH + 0.00225 newToken = 36.75
        // user is still liquidatable as liquidation threshold is 10% 

        // now we need to again liquidate the debt of 7.5 USDC which is left

        // new token is first in preference 
        // total collateral in new token -> 0.00225 * 3000 = 6.75 USDC
        // liquidation bonus -> 0.00225 * 10% bonus -> 0.000225 in collateral tokens -> 0.675 USDC 
        // so new token wipes off 6.75 - 0.675 = 6.075 USDC of debt
        
        // weETH is second in preference 
        // total collateral in weETH -> 0.01 * 3000 = 30 USDC
        // total debt left = 7.5 USDC - 6.075 USDC = 1.425 USDC
        // total collateral worth 1.425 USDC in weETH -> 1.425 / 3000 -> 0.000475
        // total bonus on 0.000475 weETH => 0.000475 * 5% = 0.00002375

        // In total
        // borrow wiped by new token -> 7.5 + 6.075 = 13.575 USDC
        // borrow wiped by weETH -> 1.425 USDC
        // total liquidation bonus new token -> 0.00025 + 0.000225 = 0.000475
        // total liquidation bonus weETH -> 0.00002375

        uint256 ownerWeETHBalBefore = weETHScroll.balanceOf(owner);
        uint256 ownerNewTokenBalBefore = IERC20(newCollateralToken).balanceOf(owner);
        uint256 aliceSafeDebtBefore = debtManager.borrowingOf(address(safe), address(usdcScroll));

        IERC20(address(usdcScroll)).approve(address(debtManager), borrowAmt);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);

        vm.stopPrank();

        _validate(newCollateralToken, ownerNewTokenBalBefore, ownerWeETHBalBefore, aliceSafeDebtBefore);
    }

    function _validate(
        address newCollateralToken,
        uint256 ownerNewTokenBalBefore,
        uint256 ownerWeETHBalBefore,
        uint256 aliceDebtBefore
    ) internal view {
        uint256 ownerWeETHBalAfter = weETHScroll.balanceOf(owner);
        uint256 ownerNewTokenBalAfter = IERC20(newCollateralToken).balanceOf(owner);
        uint256 aliceDebtAfter = debtManager.borrowingOf(address(safe), address(usdcScroll));

        uint256 borrowWipedByNewToken =  13.575 * 1e6;
        uint256 borrowWipedByWeETH = 1.425 * 1e6;
        uint256 liquidationBonusNewToken =  0.000475 ether;
        uint256 liquidationBonusWeETH = 0.00002375 ether;

        assertApproxEqAbs(
            debtManager.convertCollateralTokenToUsd(
                address(newCollateralToken),
                ownerNewTokenBalAfter - ownerNewTokenBalBefore - liquidationBonusNewToken
            ),
            borrowWipedByNewToken,
            10
        );
        
        assertApproxEqAbs(
            debtManager.convertCollateralTokenToUsd(
                address(weETHScroll),
                ownerWeETHBalAfter - ownerWeETHBalBefore - liquidationBonusWeETH
            ),
            borrowWipedByWeETH,
            10
        );

        assertEq(aliceDebtBefore, borrowAmt);
        assertEq(aliceDebtAfter, 0);
    }

    function test_liquidate_reverts_whenEmptyCollateralPreferenceProvided() public {
        vm.startPrank(owner);
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = 5e18;
        collateralTokenConfig.liquidationThreshold = 10e18;
        collateralTokenConfig.liquidationBonus = 5e18;
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);
        
        address[] memory emptyPreference = new address[](0);
        
        vm.expectRevert(IDebtManager.CollateralPreferenceIsEmpty.selector); 
        debtManager.liquidate(address(safe), address(usdcScroll), emptyPreference);
        vm.stopPrank();
    }

    function test_liquidate_reverts_whenUnsupportedRepayToken() public {
        vm.startPrank(owner);
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = 5e18;
        collateralTokenConfig.liquidationThreshold = 10e18;
        collateralTokenConfig.liquidationBonus = 5e18;
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);
        
        address randomToken = address(new MockERC20("random", "RND", 18));        
        address[] memory collateralTokenPreference = debtManager.getCollateralTokens();
        
        vm.expectRevert(IDebtManager.UnsupportedBorrowToken.selector);
        debtManager.liquidate(address(safe), randomToken, collateralTokenPreference);
        vm.stopPrank();
    }

    function test_liquidate_honorsChangedLiquidationBonus_withInsufficientCollateral() public {
        deal(address(usdcScroll), address(safe), borrowAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), borrowAmt);
        
        priceProvider = PriceProvider(
            address(new MockPriceProvider(mockWeETHPriceInUsd, address(usdcScroll)))
        );
        vm.prank(owner);
        dataProvider.setPriceProvider(address(priceProvider));
        
        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), borrowAmt, false);
        
        vm.startPrank(owner);
        uint256 newPrice = 1000e6; // 1000 USD per weETH
        MockPriceProvider(address(priceProvider)).setPrice(newPrice);
        
        // Set a very high liquidation bonus (30%)
        IDebtManager.CollateralTokenConfig memory collateralTokenConfigWeETH;
        collateralTokenConfigWeETH.ltv = 5e18;
        collateralTokenConfigWeETH.liquidationThreshold = 10e18;
        collateralTokenConfigWeETH.liquidationBonus = 30e18; // 30% bonus instead of 5%
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfigWeETH);
        
        address[] memory collateralTokenPreference = new address[](1);
        collateralTokenPreference[0] = address(weETHScroll);
        
        uint256 ownerWeETHBalBefore = weETHScroll.balanceOf(owner);
        
        IERC20(address(usdcScroll)).approve(address(debtManager), borrowAmt);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);
        
        uint256 ownerWeETHBalAfter = weETHScroll.balanceOf(owner);
        
        // Since the price dropped significantly and the total collateral is likely less than 
        // the debt after the price change, the liquidator gets the entire collateral amount
        uint256 expectedToReceive = collateralAmount; // 0.01 ether
        
        // The liquidator should receive the entire collateral
        assertApproxEqAbs(
            ownerWeETHBalAfter - ownerWeETHBalBefore,
            expectedToReceive,
            0.0001 ether
        );
        
        vm.stopPrank();
    }

    function test_liquidate_honorsChangedLiquidationBonus_withSufficientCollateral() public {
        deal(address(usdcScroll), address(safe), borrowAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), borrowAmt);
        
        // Setup mock price provider with high initial price
        priceProvider = PriceProvider(
            address(new MockPriceProvider(mockWeETHPriceInUsd, address(usdcScroll)))
        );
        vm.prank(owner);
        dataProvider.setPriceProvider(address(priceProvider));
        
        // Set up a scenario with MORE collateral
        uint256 largerCollateralAmount = 0.05 ether; // 5x more than the default 0.01 ether
        deal(address(weETHScroll), address(safe), largerCollateralAmount);
        
        // Borrow a smaller amount relative to collateral
        uint256 smallerBorrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe)) / 4; // Only borrow 25% of capacity
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), smallerBorrowAmt, false);
        
        vm.startPrank(owner);
        
        // Set a moderate price drop that makes user liquidatable but still leaves sufficient collateral
        uint256 newPrice = 2000e6; // 2000 USD per weETH (33% drop instead of 66%)
        MockPriceProvider(address(priceProvider)).setPrice(newPrice);
        
        // Set a high liquidation bonus (30%)
        IDebtManager.CollateralTokenConfig memory collateralTokenConfigWeETH;
        collateralTokenConfigWeETH.ltv = 5e18; // 5%
        collateralTokenConfigWeETH.liquidationThreshold = 10e18; // 10%
        collateralTokenConfigWeETH.liquidationBonus = 30e18; // 30% bonus
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfigWeETH);
        
        // Confirm the position is liquidatable
        assertTrue(debtManager.liquidatable(address(safe)), "Position should be liquidatable");
        
        address[] memory collateralTokenPreference = new address[](1);
        collateralTokenPreference[0] = address(weETHScroll);
        
        uint256 ownerWeETHBalBefore = weETHScroll.balanceOf(owner);
        
        // Account for the fact that _liquidateUser liquidates in two steps
        // Half in the first step, and potentially the rest in a second step if still liquidatable
        uint256 debtToLiquidate = smallerBorrowAmt;
        
        // Amount of collateral needed to cover the debt (for both liquidation steps)
        uint256 collateralNeededForDebt = debtManager.convertUsdToCollateralToken(address(weETHScroll), debtToLiquidate);
        
        // Liquidation bonus (30% of collateral needed)
        uint256 expectedBonus = (collateralNeededForDebt * collateralTokenConfigWeETH.liquidationBonus) / HUNDRED_PERCENT;
        
        // Expected total collateral to receive
        uint256 expectedCollateralToReceive = collateralNeededForDebt + expectedBonus;
        
        // Approve more than needed USDC for liquidation
        IERC20(address(usdcScroll)).approve(address(debtManager), smallerBorrowAmt);
        
        // Execute liquidation
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);
        
        uint256 ownerWeETHBalAfter = weETHScroll.balanceOf(owner);
        uint256 actualReceived = ownerWeETHBalAfter - ownerWeETHBalBefore;
                
        // The liquidator should receive exactly the debt plus the bonus
        assertApproxEqAbs(
            actualReceived,
            expectedCollateralToReceive,
            0.0001 ether
        );
        
        vm.stopPrank();
    }

    function test_liquidate_reverts_afterPriceRecovery() public {
        deal(address(usdcScroll), address(safe), borrowAmt);
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdcScroll), borrowAmt);
        
        // Setup mock price provider
        priceProvider = PriceProvider(
            address(new MockPriceProvider(mockWeETHPriceInUsd, address(usdcScroll)))
        );
        vm.prank(owner);
        dataProvider.setPriceProvider(address(priceProvider));
        
        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), keccak256("newTxId"), address(usdcScroll), borrowAmt, false);
        
        vm.startPrank(owner);
        // Drop price to make position liquidatable
        uint256 lowPrice = 1000e6; // 1000 USD per weETH
        MockPriceProvider(address(priceProvider)).setPrice(lowPrice);
        
        // Lower thresholds
        IDebtManager.CollateralTokenConfig memory collateralTokenConfigWeETH;
        collateralTokenConfigWeETH.ltv = 5e18;
        collateralTokenConfigWeETH.liquidationThreshold = 10e18;
        collateralTokenConfigWeETH.liquidationBonus = 5e18;
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfigWeETH);
        
        // Verify position is liquidatable
        assertTrue(debtManager.liquidatable(address(safe)));
        
        // Recover price
        uint256 recoveredPrice = 20000e6; // Price jumped to 20000 USD per weETH
        MockPriceProvider(address(priceProvider)).setPrice(recoveredPrice);
        
        // Position should no longer be liquidatable
        assertFalse(debtManager.liquidatable(address(safe)));
        
        // Attempt to liquidate should fail
        address[] memory collateralTokenPreference = new address[](1);
        collateralTokenPreference[0] = address(weETHScroll);
        
        vm.expectRevert(IDebtManager.CannotLiquidateYet.selector);
        debtManager.liquidate(address(safe), address(usdcScroll), collateralTokenPreference);
        
        vm.stopPrank();
    }
}