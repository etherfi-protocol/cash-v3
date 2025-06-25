// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { Mode, SafeCashData, BinSponsor, SafeData, Cashback, CashbackTokens, CashbackTypes } from "../../../../src/interfaces/ICashModule.sol";
import { IEtherFiSafeFactory } from "../../../../src/interfaces/IEtherFiSafeFactory.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import { SpendingLimit } from "../../../../src/libraries/SpendingLimitLib.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../src/oracle/PriceProvider.sol"; 
import { ILayerZeroTeller, AccountantWithRateProviders } from "../../../../src/interfaces/ILayerZeroTeller.sol";


contract CashLensTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    IERC20 public liquidUsdScroll = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    ILayerZeroTeller public liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        AccountantWithRateProviders liquidUsdAccountant = liquidUsdTeller.accountant();

        PriceProvider.Config memory liquidUsdConfig = PriceProvider.Config({
            oracle: address(liquidUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(liquidUsdScroll);

        PriceProvider.Config[] memory tokensConfig = new PriceProvider.Config[](1);
        tokensConfig[0] = liquidUsdConfig;

        priceProvider.setTokenConfig(tokens, tokensConfig);

        IDebtManager.CollateralTokenConfig[] memory collateralTokenConfig = new IDebtManager.CollateralTokenConfig[](1);

        collateralTokenConfig[0].ltv = ltv;
        collateralTokenConfig[0].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[0].liquidationBonus = liquidationBonus;

        debtManager.supportCollateralToken(address(liquidUsdScroll), collateralTokenConfig[0]);        

        minShares = uint128(10 * 10 ** IERC20Metadata(address(liquidUsdScroll)).decimals());
        debtManager.supportBorrowToken(address(liquidUsdScroll), borrowApyPerSecond, minShares);

        // Add some collateral to safe for tests
        deal(address(weETHScroll), address(safe), 10 ether);
        deal(address(usdcScroll), address(safe), 50000e6);
        
        // Ensure debt manager has sufficient liquidity
        deal(address(usdcScroll), address(debtManager), 100000e6);

        vm.stopPrank();
    }

    function test_getUserCollateralForToken() public {
        uint256 depositAmount = 5 ether;
        deal(address(weETHScroll), address(safe), depositAmount);
        
        // Check initial collateral
        uint256 collateral = cashLens.getUserCollateralForToken(address(safe), address(weETHScroll));
        assertEq(collateral, depositAmount, "Initial collateral should match deposit");
        
        // Create a withdrawal request
        address[] memory tokens = new address[](1);
        tokens[0] = address(weETHScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2 ether; // Withdraw 2 ETH
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        // Check collateral after withdrawal request
        collateral = cashLens.getUserCollateralForToken(address(safe), address(weETHScroll));
        assertEq(collateral, depositAmount - 2 ether, "Collateral should be reduced by withdrawal amount");
    }

    function test_getUserCollateralForToken_nonCollateralToken() public {
        address nonCollateralToken = makeAddr("nonCollateralToken");
        
        vm.expectRevert(CashLens.NotACollateralToken.selector);
        cashLens.getUserCollateralForToken(address(safe), nonCollateralToken);
    }

    function test_getUserTotalCollateral() public {
        // Add multiple collateral types
        deal(address(weETHScroll), address(safe), 5 ether);
        deal(address(usdcScroll), address(safe), 10000e6);
        
        // Check initial collateral
        IDebtManager.TokenData[] memory collateral = cashLens.getUserTotalCollateral(address(safe));
        
        // Should have two collateral entries
        assertEq(collateral.length, 2, "Should have two collateral tokens");
        
        // Create withdrawal requests
        address[] memory tokens = new address[](2);
        tokens[0] = address(weETHScroll);
        tokens[1] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2 ether;     // Withdraw 2 ETH
        amounts[1] = 5000e6;      // Withdraw 5000 USDC
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        // Check collateral after withdrawal request
        collateral = cashLens.getUserTotalCollateral(address(safe));
        
        // Should still have two entries but with reduced amounts
        assertEq(collateral.length, 2, "Should still have two collateral tokens");
        
        // Find the right token in the array and check the amount
        for (uint256 i = 0; i < collateral.length; i++) {
            if (collateral[i].token == address(weETHScroll)) {
                assertEq(collateral[i].amount, 3 ether, "weETH amount should be reduced by withdrawal");
            } else if (collateral[i].token == address(usdcScroll)) {
                assertEq(collateral[i].amount, 5000e6, "USDC amount should be reduced by withdrawal");
            }
        }
    }

    function test_getSafeCashData() public {
        // Setup test state
        deal(address(weETHScroll), address(safe), 5 ether);
        deal(address(usdcScroll), address(safe), 10000e6);
        
        // Create a withdrawal request
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        // Get safe cash data
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), new address[](0));
        
        // Verify basic data
        assertEq(uint8(data.mode), uint8(Mode.Debit), "Initial mode should be Debit");
        assertEq(data.incomingCreditModeStartTime, 0, "No incoming credit mode change");
        assertEq(data.totalCashbackEarnedInUsd, 0, "No cashback earned initially");
        
        // Verify collateral and borrows
        assertEq(data.collateralBalances.length, 2, "Should have two collateral entries");
        assertEq(data.borrows.length, 0, "Should have no borrows initially");
        
        // Verify withdrawal request
        assertEq(data.withdrawalRequest.tokens.length, 1, "Should have one withdrawal token");
        assertEq(data.withdrawalRequest.amounts.length, 1, "Should have one withdrawal amount");
        assertEq(data.withdrawalRequest.tokens[0], address(usdcScroll), "Withdrawal token should be USDC");
        assertEq(data.withdrawalRequest.amounts[0], 5000e6, "Withdrawal amount should be 5000 USDC");
        
        // Verify total values
        assertGt(data.totalCollateral, 0, "Total collateral should be positive");
        assertEq(data.totalBorrow, 0, "Total borrow should be zero initially");
        assertGt(data.maxBorrow, 0, "Max borrow should be positive");
    }

    function test_getSafeCashData_inCreditMode() public {
        // Setup test state
        deal(address(weETHScroll), address(safe), 5 ether);
        deal(address(usdcScroll), address(safe), 10000e6);
        
        // Set to credit mode
        _setMode(Mode.Credit);
        
        // Get safe cash data before credit mode is active
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), new address[](0));
        
        // Verify mode is still Debit but incoming change is recorded
        assertEq(uint8(data.mode), uint8(Mode.Debit), "Mode should still be Debit");
        assertGt(data.incomingCreditModeStartTime, 0, "Should have incoming credit mode start time");
        
        // Fast forward to after credit mode start time
        vm.warp(data.incomingCreditModeStartTime + 1);
        
        // Get updated safe cash data
        data = cashLens.getSafeCashData(address(safe), new address[](0));
        
        // Verify mode is now Credit
        assertEq(uint8(data.mode), uint8(Mode.Credit), "Mode should now be Credit");
    }

    function test_getSafeCashData_withBorrows() public {
        // Setup test state
        deal(address(weETHScroll), address(safe), 5 ether);
        
        // Set to credit mode and wait for it to activate
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 spendAmount = 1000e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        // Spend in credit mode to create a borrow
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Get safe cash data
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), new address[](0));
        
        // Verify borrows
        assertEq(data.borrows.length, 1, "Should have one borrow entry");
        assertEq(data.borrows[0].token, address(usdcScroll), "Borrow token should be USDC");
        assertApproxEqAbs(data.borrows[0].amount, spendAmount, 1, "Borrow amount should match spend amount");
        
        // Verify total borrow
        assertApproxEqAbs(data.totalBorrow, spendAmount, 1, "Total borrow should match spend amount");
    }

    function test_applicableSpendingLimit() public {
        // Get initial spending limit
        SpendingLimit memory limit = cashLens.applicableSpendingLimit(address(safe));
        
        // Verify initial values
        assertEq(limit.dailyLimit, dailyLimitInUsd, "Daily limit should match setup value");
        assertEq(limit.monthlyLimit, monthlyLimitInUsd, "Monthly limit should match setup value");
        assertEq(limit.spentToday, 0, "No spending initially");
        assertEq(limit.spentThisMonth, 0, "No spending initially");
        
        // Update spending limit to lower values
        uint256 newDailyLimit = dailyLimitInUsd / 2;
        uint256 newMonthlyLimit = monthlyLimitInUsd / 2;
        _updateSpendingLimit(newDailyLimit, newMonthlyLimit);
        
        // Get updated spending limit
        limit = cashLens.applicableSpendingLimit(address(safe));
        
        // Since we're lowering the limits, they should be pending with activation times
        assertEq(limit.dailyLimit, dailyLimitInUsd, "Daily limit should still be old value");
        assertEq(limit.monthlyLimit, monthlyLimitInUsd, "Monthly limit should still be old value");
        assertEq(limit.newDailyLimit, newDailyLimit, "New daily limit should match updated value");
        assertEq(limit.newMonthlyLimit, newMonthlyLimit, "New monthly limit should match updated value");
        assertGt(limit.dailyLimitChangeActivationTime, 0, "Should have activation time for daily limit");
        assertGt(limit.monthlyLimitChangeActivationTime, 0, "Should have activation time for monthly limit");
        
        // Fast forward past activation time
        (, uint64 spendLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendLimitDelay + 1);
        
        // Get updated spending limit
        limit = cashLens.applicableSpendingLimit(address(safe));
        
        // New limits should be active
        assertEq(limit.dailyLimit, newDailyLimit, "Daily limit should now be updated value");
        assertEq(limit.monthlyLimit, newMonthlyLimit, "Monthly limit should now be updated value");
        assertEq(limit.newDailyLimit, 0, "No pending daily limit change");
        assertEq(limit.newMonthlyLimit, 0, "No pending monthly limit change");
        assertEq(limit.dailyLimitChangeActivationTime, 0, "No pending activation time for daily limit");
        assertEq(limit.monthlyLimitChangeActivationTime, 0, "No pending activation time for monthly limit");
    }

    function test_getPendingWithdrawalAmount() public {
        // Initially no withdrawals
        uint256 amount = cashLens.getPendingWithdrawalAmount(address(safe), address(usdcScroll));
        assertEq(amount, 0, "No pending withdrawals initially");
        
        // Create a withdrawal request
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        // Check withdrawal amount
        amount = cashLens.getPendingWithdrawalAmount(address(safe), address(usdcScroll));
        assertEq(amount, 5000e6, "Should have pending withdrawal");
        
        // Check non-existent withdrawal
        amount = cashLens.getPendingWithdrawalAmount(address(safe), address(weETHScroll));
        assertEq(amount, 0, "Should have no pending withdrawal for weETH");
    }

    function test_calculateCreditModeAmount_noCollateral() public {
        // Create a new safe with no collateral
        address safeDummy = makeAddr("safeDummy");

        vm.mockCall(
            address(safeFactory),
            abi.encodeWithSelector(IEtherFiSafeFactory.isEtherFiSafe.selector, safeDummy),
            abi.encode(true)
        );
        
        // Get the safe data structure
        SafeData memory safeData = cashModule.getData(address(safe));
        safeData.mode = Mode.Credit;
                
        uint256 creditMaxSpend = cashLens.getMaxSpendCredit(safeDummy);
        
        assertEq(creditMaxSpend, 0, "Credit max spend should be zero with no collateral");
    }

    function test_calculateDebitModeAmount_zeroBalance() public {
        // Set up a safe with insufficient collateral
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        
        address[] memory modules = new address[](1);
        modules[0] = address(cashModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);
        
        vm.prank(owner);
        safeFactory.deployEtherFiSafe(keccak256("insufficientSafe"), owners, modules, setupData, 1);
        address insufficientSafe = safeFactory.getDeterministicAddress(keccak256("insufficientSafe"));
                
        // Set to credit mode and borrow more than collateral value
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);
        
        
        // Calculate max debit spend - should be zero due to 0 collateral
        uint256 debitMaxSpend = cashLens.getMaxSpendDebit(insufficientSafe, debtManager.getBorrowTokens()).totalSpendableInUsd;
        
        assertEq(debitMaxSpend, 0, "Debit max spend should be zero with insufficient collateral");
    }

    function test_getUserTotalCollateral_zeroBalance() public {
        // Create a new safe with no balance
        address safeDummy = makeAddr("safeDummy");

        vm.mockCall(
            address(safeFactory),
            abi.encodeWithSelector(IEtherFiSafeFactory.isEtherFiSafe.selector, safeDummy),
            abi.encode(true)
        );
        
        // Get collateral
        IDebtManager.TokenData[] memory collateral = cashLens.getUserTotalCollateral(safeDummy);
        
        // Should have zero entries
        assertEq(collateral.length, 0, "Should have no collateral entries with zero balance");
    }

    function test_getCollateralBalanceWithTokensSubtracted_allTokens() public {
        // Setup test state with multiple tokens
        deal(address(weETHScroll), address(safe), 5 ether);
        deal(address(usdcScroll), address(safe), 10000e6);
        
        // Simulate spending all tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(weETHScroll);
        
        uint256[] memory amountsInUsd = new uint256[](2);
        amountsInUsd[0] = debtManager.convertCollateralTokenToUsd(address(usdcScroll), 10000e6);
        amountsInUsd[1] = debtManager.convertCollateralTokenToUsd(address(weETHScroll), 5 ether);
        
        // Set to debit mode to test subtraction
        SafeData memory safeData = cashModule.getData(address(safe));
        safeData.mode = Mode.Debit;
        
        // Test through canSpend which calls _getCollateralBalanceWithTokensSubtracted
        (bool canSpend, ) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Cannot spend all tokens as it would leave no collateral");
    }
}