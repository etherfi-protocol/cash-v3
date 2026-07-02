// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { ICashModule, Mode, BinSponsor, Cashback, CashbackTokens } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IGateway } from "../../../../src/interfaces/IGateway.sol";
import { SpendingLimitLib } from "../../../../src/libraries/SpendingLimitLib.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import { UpgradeableProxy } from "../../../../src/utils/UpgradeableProxy.sol";

contract CashModuleMultiSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    // Setup another supported token for testing multi-token spending
    function setUp() public override {
        super.setUp();
        
        // Support weETH as another borrow token
        vm.prank(owner);
        debtManager.supportBorrowToken(address(weETH), borrowApyPerSecond, minShares);
    }

    function test_spend_variousTokenProportions_inDebitMode() public {
        address[] memory spendTokens = new address[](2);
        uint256[] memory spendAmounts = new uint256[](2);
        uint256[] memory tokenAmounts = new uint256[](2);
        {
            // Setup: Different token amounts with same USD value
            uint256 usdcAmountInUsd = 50e6; // $50 in USDC
            uint256 weETHAmountInUsd = 50e6; // $50 in weETH
            
            // Convert to token amounts
            uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
            uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
            
            // Fund the safe with both tokens
            deal(address(usdc), address(safe), usdcAmount);
            deal(address(weETH), address(safe), weETHAmount);
            
            // Create spending transaction with multiple tokens
            spendTokens[0] = address(usdc);
            spendTokens[1] = address(weETH);
            
            spendAmounts[0] = usdcAmountInUsd;
            spendAmounts[1] = weETHAmountInUsd;

            tokenAmounts[0] = usdcAmount;
            tokenAmounts[1] = weETHAmount;
        }
        
        // Track initial balances
        uint256 settlementDispatcherUsdcBalBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 settlementDispatcherWeETHBalBefore = weETH.balanceOf(address(settlementDispatcherReap));

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Execute spend
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, tokenAmounts, spendAmounts, spendAmounts[0] + spendAmounts[1], Mode.Debit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(weETH.balanceOf(address(safe)), 0);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherUsdcBalBefore + tokenAmounts[0]);
        assertEq(weETH.balanceOf(address(settlementDispatcherReap)), settlementDispatcherWeETHBalBefore + tokenAmounts[1]);
    }

    function test_spend_asymmetricalTokenDistribution_inDebitMode() public {        
        // Create spending transaction with multiple tokens
        address[] memory spendTokens = new address[](2);
        uint256[] memory spendAmounts = new uint256[](2);
        uint256[] memory tokenAmounts = new uint256[](2);

        {
            // Setup: Asymmetrical token distribution (80% USDC, 20% weETH)
            uint256 usdcAmountInUsd = 80e6; // $80 in USDC
            uint256 weETHAmountInUsd = 20e6; // $20 in weETH
            
            // Convert to token amounts
            uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
            uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
            
            // Fund the safe with both tokens
            deal(address(usdc), address(safe), usdcAmount * 2); // Give extra for follow-up test
            deal(address(weETH), address(safe), weETHAmount * 2); // Give extra for follow-up test

            spendTokens[0] = address(usdc);
            spendTokens[1] = address(weETH);
            
            spendAmounts[0] = usdcAmountInUsd;
            spendAmounts[1] = weETHAmountInUsd;

            tokenAmounts[0] = usdcAmount;
            tokenAmounts[1] = weETHAmount;
        }

        {
            // Track initial balances
            uint256 settlementDispatcherUsdcBalBefore = usdc.balanceOf(address(settlementDispatcherReap));
            uint256 settlementDispatcherWeETHBalBefore = weETH.balanceOf(address(settlementDispatcherReap));

            Cashback[] memory cashbacks = new Cashback[](1);
            CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

            CashbackTokens memory scr = CashbackTokens({
                token: address(cashbackToken),
                amountInUsd: 1e6,
                cashbackType: 0
            });

            cashbackTokens[0] = scr;

            Cashback memory scrCashback = Cashback({
                to: address(safe),
                cashbackTokens: cashbackTokens
            });

            cashbacks[0] = scrCashback;
            
            // Execute spend
            vm.prank(etherFiWallet);
            vm.expectEmit(true, true, true, true);
            emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, tokenAmounts, spendAmounts, spendAmounts[0] + spendAmounts[1], Mode.Debit);
            cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
            
            // Verify tokens were transferred to settlement dispatcher
            assertEq(usdc.balanceOf(address(safe)), tokenAmounts[0]);
            assertEq(weETH.balanceOf(address(safe)), tokenAmounts[1]);
            assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherUsdcBalBefore + tokenAmounts[0]);
            assertEq(weETH.balanceOf(address(settlementDispatcherReap)), settlementDispatcherWeETHBalBefore + tokenAmounts[1]);

            // Execute another spend with different transaction ID
            bytes32 txId2 = keccak256("txId2");
            vm.prank(etherFiWallet);
            cashModule.spend(address(safe), txId2, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
            
            // Verify tokens were transferred again
            assertEq(usdc.balanceOf(address(safe)), 0);
            assertEq(weETH.balanceOf(address(safe)), 0);
            assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherUsdcBalBefore + tokenAmounts[0] * 2);
            assertEq(weETH.balanceOf(address(settlementDispatcherReap)), settlementDispatcherWeETHBalBefore + tokenAmounts[1] * 2);
        }
        
    }

    function test_spend_failsWithInsufficientBalance_oneToken() public {
        // Setup: Fund the safe with enough of one token but not enough of another
        uint256 usdcAmountInUsd = 50e6;
        uint256 weETHAmountInUsd = 50e6;
        
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        
        // Only fund with USDC, not with weETH
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), 0); // No weETH
        
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = usdcAmountInUsd;
        spendAmounts[1] = weETHAmountInUsd;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Should revert due to insufficient weETH balance
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_failsWithInsufficientBalance_partialAmount() public {
        // Setup: Fund the safe with enough of one token but only partial amount of another
        uint256 usdcAmountInUsd = 50e6;
        uint256 weETHAmountInUsd = 50e6;
        
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
        
        // Fund with full USDC amount, but only half of the weETH amount
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHAmount / 2);
        
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = usdcAmountInUsd;
        spendAmounts[1] = weETHAmountInUsd;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Should revert due to insufficient weETH balance
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_withCashback_multipleTokens() public {
        uint256 usdcAmountInUsd = 50e6;
        uint256 weETHAmountInUsd = 50e6;
        
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
        
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHAmount);
        
        uint256 safeTokenBalBefore = cashbackToken.balanceOf(address(safe));
        
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = usdcAmountInUsd;
        spendAmounts[1] = weETHAmountInUsd;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Execute spend with cashback
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Verify cashback was received
        assertGt(cashbackToken.balanceOf(address(safe)), safeTokenBalBefore);
    }

    function test_spend_exceedsDailyLimit_multipleTokens() public {
        // Setup: Fund the safe with both tokens
        uint256 usdcAmountInUsd = dailyLimitInUsd / 2 + 1e6;  // Just over half the daily limit
        uint256 weETHAmountInUsd = dailyLimitInUsd / 2 + 1e6; // Just over half the daily limit
        
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
        
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHAmount);
        
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = usdcAmountInUsd;
        spendAmounts[1] = weETHAmountInUsd;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Should revert as total spending exceeds daily limit
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_withPendingWithdrawal_multipleTokens() public {
        // Setup test parameters
        WithdrawalTestData memory data = _setupWithdrawalTest();
        
        // Setup initial balances tracking
        uint256 usdcBalanceBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 weETHBalanceBefore = weETH.balanceOf(address(settlementDispatcherReap));

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Execute spend
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, data.spendTokens, data.spendAmounts, cashbacks);
        
        // Verify correct token balances after spend
        _verifyWithdrawalTestResults(data, usdcBalanceBefore, weETHBalanceBefore);
    }
    
    // Helper struct to store test data
    struct WithdrawalTestData {
        uint256 usdcAmountInUsd;
        uint256 weETHAmountInUsd;
        uint256 withdrawalAmountInUsd;
        uint256 withdrawalAmount;
        address[] spendTokens;
        uint256[] spendAmounts;
    }
    
    // Helper function to set up the withdrawal test
    function _setupWithdrawalTest() internal returns (WithdrawalTestData memory data) {
        data.usdcAmountInUsd = 60e6;
        data.weETHAmountInUsd = 50e6;
        data.withdrawalAmountInUsd = 20e6;
        
        // Convert amounts to token units
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), data.usdcAmountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), data.weETHAmountInUsd);
        data.withdrawalAmount = debtManager.convertUsdToCollateralToken(address(usdc), data.withdrawalAmountInUsd);
        
        // Fund the safe
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHAmount);
        
        // Setup a pending withdrawal for USDC
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = data.withdrawalAmount;
        
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), data.withdrawalAmount);
        
        // Prepare spend tokens and amounts
        data.spendTokens = new address[](2);
        data.spendTokens[0] = address(usdc);
        data.spendTokens[1] = address(weETH);
        
        data.spendAmounts = new uint256[](2);
        data.spendAmounts[0] = data.usdcAmountInUsd - data.withdrawalAmountInUsd;  // Spend all except withdrawal amount
        data.spendAmounts[1] = data.weETHAmountInUsd;
        
        return data;
    }
    
    // Helper function to verify the withdrawal test results
    function _verifyWithdrawalTestResults(
        WithdrawalTestData memory data, 
        uint256 usdcBalanceBefore, 
        uint256 weETHBalanceBefore
    ) internal view {
        // Calculate expected USDC spend amount
        uint256 expectedUsdcAmount = debtManager.convertUsdToCollateralToken(
            address(usdc), 
            data.usdcAmountInUsd - data.withdrawalAmountInUsd
        );
        
        // Expected weETH spend amount
        uint256 expectedWeETHAmount = debtManager.convertUsdToCollateralToken(
            address(weETH), 
            data.weETHAmountInUsd
        );
        
        // Verify safe balances
        assertEq(usdc.balanceOf(address(safe)), data.withdrawalAmount);
        assertEq(weETH.balanceOf(address(safe)), 0);
        
        // Verify settlement dispatcher balances
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), usdcBalanceBefore + expectedUsdcAmount);
        assertEq(weETH.balanceOf(address(settlementDispatcherReap)), weETHBalanceBefore + expectedWeETHAmount);
        
        // Verify pending withdrawal still exists
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), data.withdrawalAmount);
    }


    function test_spend_switchToCreditModeFails_multipleTokens() public {
        // Setup: Fund the safe with both tokens
        uint256 usdcAmountInUsd = 50e6;
        uint256 weETHAmountInUsd = 50e6;
        
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
        
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHAmount);
        
        // Switch to credit mode
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = usdcAmountInUsd;
        spendAmounts[1] = weETHAmountInUsd;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Should revert as multiple tokens are not allowed in credit mode
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyOneTokenAllowedInCreditMode.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_whenPaused_multipleTokens() public {
        // Setup: Fund the safe with both tokens
        uint256 usdcAmountInUsd = 50e6;
        uint256 weETHAmountInUsd = 50e6;
        
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
        
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHAmount);
        
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = usdcAmountInUsd;
        spendAmounts[1] = weETHAmountInUsd;
        
        // Pause the contract
        vm.prank(pauser);
        UpgradeableProxy(address(cashModule)).pause();

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Attempt to spend while paused
        vm.prank(etherFiWallet);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Unpause and verify it works again
        vm.prank(unpauser);
        UpgradeableProxy(address(cashModule)).unpause();
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_withThreeTokens_inDebitMode() public {
        // We'll add a third token (SCR token) for this test
        vm.startPrank(owner);
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig = IDebtManager.CollateralTokenConfig({ltv: ltv, liquidationThreshold: liquidationThreshold, liquidationBonus: liquidationBonus});
        debtManager.supportCollateralToken(address(cashbackToken), collateralTokenConfig);
        debtManager.supportBorrowToken(address(cashbackToken), borrowApyPerSecond, minShares);
        vm.stopPrank();
        
        // Setup three tokens with sample amounts
        uint256 usdcAmountInUsd = 40e6; // $40 in USDC
        uint256 weETHAmountInUsd = 30e6; // $30 in weETH
        uint256 scrAmountInUsd = 30e6; // $30 in SCR
        uint256 totalSpendInUsd = usdcAmountInUsd + weETHAmountInUsd + scrAmountInUsd;
        
        // Convert to token amounts and fund the safe
        _fundSafeWithTokenAmount(address(usdc), usdcAmountInUsd);
        _fundSafeWithTokenAmount(address(weETH), weETHAmountInUsd);
        _fundSafeWithTokenAmount(address(cashbackToken), scrAmountInUsd);
        
        // Store initial balances
        uint256[] memory initialBalances = _getSettlementDispatcherBalances();
        
        // Prepare and execute multi-token spend
        (address[] memory spendTokens, uint256[] memory spendAmounts, uint256[] memory tokenAmounts) = 
            _prepareThreeTokenSpend(usdcAmountInUsd, weETHAmountInUsd, scrAmountInUsd);

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(cashbackToken),
            amountInUsd: 1e6,
            cashbackType: 0
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Execute spend
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, tokenAmounts, spendAmounts, totalSpendInUsd, Mode.Debit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Verify safe balances are zero, not for scroll since there was cashback
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(weETH.balanceOf(address(safe)), 0);
        
        // Verify settlement dispatcher received the tokens
        uint256[] memory expectedIncreases = new uint256[](3);
        expectedIncreases[0] = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        expectedIncreases[1] = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
        expectedIncreases[2] = debtManager.convertUsdToCollateralToken(address(cashbackToken), scrAmountInUsd);
        
        _verifySettlementDispatcherBalances(initialBalances, expectedIncreases);
    }

    // Debit spend across two tokens while the safe carries Aave debt: usdc is fully sourced from the loose
    // balance, weETH from a mix of loose and Aave-supplied balance, and the supplied withdrawal is sized
    // against the borrowing headroom.
    function test_spend_multiToken_mixedLooseAndSupplied_withDebt() public {
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), 50e6); // fully from the loose balance
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), 40e6); // part loose, part from Aave
        uint256 weETHLoose = debtManager.convertUsdToCollateralToken(address(weETH), 10e6); // $10 of the weETH sits loose

        // Fund loose balances; weETH's remaining spend is backed by its Aave-supplied balance.
        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHLoose);
        gateway.setLtv(address(usdc), 80e18);
        gateway.setLtv(address(weETH), 80e18);
        gateway.setSuppliedOf(address(safe), address(weETH), weETHAmount);
        gateway.setAvailableCash(address(weETH), type(uint128).max);

        // Safe carries debt with ample borrowing headroom, so the weETH withdrawal is allowed.
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 500e6, debtUsd: 100e6, availableBorrowsUsd: 100e6, healthFactor: 1e18 }));

        uint256 dispatcherUsdcBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 dispatcherWeETHBefore = weETH.balanceOf(address(settlementDispatcherReap));

        {
            address[] memory spendTokens = new address[](2);
            spendTokens[0] = address(usdc);
            spendTokens[1] = address(weETH);
            uint256[] memory spendAmounts = new uint256[](2);
            spendAmounts[0] = 50e6;
            spendAmounts[1] = 40e6;
            uint256[] memory tokenAmounts = new uint256[](2);
            tokenAmounts[0] = usdcAmount;
            tokenAmounts[1] = weETHAmount;

            Cashback[] memory cashbacks;

            vm.prank(etherFiWallet);
            vm.expectEmit(true, true, true, true);
            emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, tokenAmounts, spendAmounts, 90e6, Mode.Debit);
            cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        }

        // Loose balances of both tokens are drained to the dispatcher.
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(weETH.balanceOf(address(safe)), 0);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherUsdcBefore + usdcAmount);
        assertEq(weETH.balanceOf(address(settlementDispatcherReap)), dispatcherWeETHBefore + weETHLoose);

        // The weETH shortfall is withdrawn from the Aave-supplied balance via the gateway (usdc needed no withdrawal).
        (address s, address asset, uint256 amt, address to) = gateway.lastWithdraw();
        assertEq(s, address(safe));
        assertEq(asset, address(weETH));
        assertEq(amt, weETHAmount - weETHLoose);
        assertEq(to, address(settlementDispatcherReap));
    }

    // With debt, the borrowing headroom is shared across every token in one debit: usdc's Aave withdrawal
    // consumes it first, leaving too little for weETH's, so the spend reverts. Either token alone would fit.
    function test_spend_multiToken_revertsWhenSuppliedDrawsExceedSharedHeadroom_withDebt() public {
        // Both tokens are sourced from their Aave-supplied balances (no loose funding).
        gateway.setLtv(address(usdc), 80e18);
        gateway.setLtv(address(weETH), 80e18);
        gateway.setSuppliedOf(address(safe), address(usdc), debtManager.convertUsdToCollateralToken(address(usdc), 100e6));
        gateway.setSuppliedOf(address(safe), address(weETH), debtManager.convertUsdToCollateralToken(address(weETH), 100e6));
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setAvailableCash(address(weETH), type(uint128).max);

        // $40 headroom at 80% LTV funds $50 of withdrawals in total. usdc's $30 draw spends $24 of it, leaving
        // room for only $20 of weETH, short of its $30 draw.
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 500e6, debtUsd: 100e6, availableBorrowsUsd: 40e6, healthFactor: 1e18 }));

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

        // Helper function to fund the safe with a specific token amount
    function _fundSafeWithTokenAmount(address token, uint256 amountInUsd) internal {
        uint256 amount = debtManager.convertUsdToCollateralToken(token, amountInUsd);
        deal(token, address(safe), amount);
    }
    
    // Helper function to get settlement dispatcher balances for the three tokens
    function _getSettlementDispatcherBalances() internal view returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](3);
        balances[0] = usdc.balanceOf(address(settlementDispatcherReap));
        balances[1] = weETH.balanceOf(address(settlementDispatcherReap));
        balances[2] = cashbackToken.balanceOf(address(settlementDispatcherReap));
        return balances;
    }
    
    // Helper function to verify settlement dispatcher balances have increased correctly
    function _verifySettlementDispatcherBalances(
        uint256[] memory initialBalances, 
        uint256[] memory expectedIncreases
    ) internal view {
        assertEq(
            usdc.balanceOf(address(settlementDispatcherReap)), 
            initialBalances[0] + expectedIncreases[0]
        );
        assertEq(
            weETH.balanceOf(address(settlementDispatcherReap)), 
            initialBalances[1] + expectedIncreases[1]
        );
        assertEq(
            cashbackToken.balanceOf(address(settlementDispatcherReap)),
            initialBalances[2] + expectedIncreases[2]
        );
    }
    
    // Helper function to prepare three token spend arrays
    function _prepareThreeTokenSpend(
        uint256 usdcAmountInUsd, 
        uint256 weETHAmountInUsd, 
        uint256 scrAmountInUsd
    ) internal view returns (
        address[] memory spendTokens, 
        uint256[] memory spendAmounts,
        uint256[] memory tokenAmounts
    ) {
        spendTokens = new address[](3);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        spendTokens[2] = address(cashbackToken);
        
        spendAmounts = new uint256[](3);
        spendAmounts[0] = usdcAmountInUsd;
        spendAmounts[1] = weETHAmountInUsd;
        spendAmounts[2] = scrAmountInUsd;
        
        tokenAmounts = new uint256[](3);
        tokenAmounts[0] = debtManager.convertUsdToCollateralToken(address(usdc), usdcAmountInUsd);
        tokenAmounts[1] = debtManager.convertUsdToCollateralToken(address(weETH), weETHAmountInUsd);
        tokenAmounts[2] = debtManager.convertUsdToCollateralToken(address(cashbackToken), scrAmountInUsd);
        
        return (spendTokens, spendAmounts, tokenAmounts);
    }
}