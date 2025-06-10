// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { PriceProvider, IAggregatorV3 } from "../../../../src/oracle/PriceProvider.sol"; 
import { Mode, BinSponsor, Cashback, CashbackTokens, CashbackTypes } from "../../../../src/interfaces/ICashModule.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";

contract CashLensCanSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    IERC20 public liquidUsdScroll = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        PriceProvider.Config memory liquidUsdConfig = PriceProvider.Config({
            oracle: usdcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(),
            maxStaleness: type(uint24).max,
            dataType: PriceProvider.ReturnType.Int256,
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

        Cashback[] memory cashbacks = new Cashback[](1);
        cashbacks[0] = scrCashback;

        vm.stopPrank();
    }

    function test_canSpend_succeeds_inDebitMode_whenBalanceAvailable() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        
        deal(address(usdcScroll), address(safe), amounts[0]);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_succeeds_inCreditMode_whenCollateralAvailable() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        deal(address(weETHScroll), address(safe), 1 ether);
        deal(address(usdcScroll), address(debtManager), amounts[0]);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenBalanceTooLow() public view {
        uint256 bal = usdcScroll.balanceOf(address(safe));

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = bal + 1;
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient token balance for debit mode spending");
    }

    function test_canSpend_fails_inCreditMode_whenLiquidityUnavailableInDebtManager() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        deal(address(weETHScroll), address(safe), 1 ether);
        deal(address(usdcScroll), address(debtManager), amounts[0] - 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient liquidity in debt manager to cover the loan");
    }

    function test_canSpend_succeeds_inDebitMode_whenWithdrawalIsLowerThanAmountRequested() public {
        uint256 totalBal = 1000e6;
        uint256 withdrawalBal = 900e6;
        uint256 balToTransfer = totalBal - withdrawalBal;

        deal(address(usdcScroll), address(safe), totalBal);

        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(usdcScroll);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = withdrawalBal;
        _requestWithdrawal(withdrawTokens, withdrawAmounts, withdrawRecipient);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = balToTransfer;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_succeeds_inCreditMode_whenAfterWithdrawalAmountIsStillBorrowable() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        deal(address(usdcScroll), address(debtManager), 1 ether);
        uint256 totalBal = 1000e6;
        uint256 withdrawalAmt = 200e6;
        uint256 balToTransfer = 400e6; // still with 800 USDC after withdrawal we can borrow 400 USDC as ltv = 50%
        deal(address(usdcScroll), address(safe), totalBal);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmt;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        amounts[0] = balToTransfer;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenWithdrawalRequestBlocksIt() public {
        address token = address(usdcScroll);
        uint256 bal = 100e6;
        deal(token, address(safe), bal);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        amounts[0] = bal;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient effective balance after withdrawal to spend with debit mode");
    }

    function test_canSpend_fails_inCreditMode_whenWithdrawalRequestBlocksIt() public {
        address token = address(usdcScroll);
        uint256 bal = 100e6;
        deal(token, address(safe), bal);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        _setMode(Mode.Credit);

        // since we have 100 USDC and 10 is in withdrawal, also incoming mode is credit
        // with 90% ltv, max borrowable is (100 - 10) * 90% = 81 USDC
        // if we want to borrow 82 USDC, it should fail
        amounts[0] = 82e6;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient borrowing power");
    }

    function test_canSpend_fails_inCreditMode_whenCollateralBalanceIsZero() public {
        _setMode(Mode.Credit);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient borrowing power");
    }

    function test_canSpend_fails_inDebitMode_whenWithdrawalRequestBlocksItWithMultipleTokens() public {
        address token = address(usdcScroll);
        uint256 bal = 100e6;
        deal(token, address(safe), bal);
        deal(address(weETHScroll), address(safe), bal);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weETHScroll);
        tokens[1] = token;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e6;
        amounts[1] = 10e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = bal;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, spendTokens, spendAmounts);
        assertEq(canSpend, false);
        assertEq(reason, "Insufficient effective balance after withdrawal to spend with debit mode");
    }

    function test_canSpend_fails_whenTxIdIsAlreadyCleared() public {
        deal(address(usdcScroll), address(safe), 100 ether);
        uint256 amountToSpend = 100e6;

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSpend;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amounts, cashbacks);


        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Transaction already cleared");
    }

    function test_canSpend_fails_inDebitMode_whenDailySpendingLimitIsTooLow() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), amountToSpend);
        _updateSpendingLimit(amountToSpend - 1, 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSpend;

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");
    }

    function test_canSpend_fails_inDebitMode_whenDailySpendingLimitIsExhausted() public {
        deal(address(usdcScroll), address(safe), 100 ether);
        uint256 amountToSpend = 100e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = dailyLimitInUsd - amountToSpend + 1;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSpend;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");
    }

    function test_canSpend_succeeds_inDebitMode_whenSpendingLimitRenews() public {
        deal(address(usdcScroll), address(safe), 100 ether);
        uint256 amountToSpend = 100e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = dailyLimitInUsd - amountToSpend + 1;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSpend;

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp + 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenIncomingDailySpendingLimitIsTooLow() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), amountToSpend);
        _updateSpendingLimit(amountToSpend - 1, 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSpend;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Incoming daily available spending limit less than amount requested");
    }

    function test_canSpend_fails_inDebitMode_whenIncomingDailySpendingLimitIsExhausted() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), 10 ether);
        _updateSpendingLimit(amountToSpend - 1, 1 ether);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 1;

        Cashback[] memory cashbacks;

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSpend;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp + 1);
        (canSpend, reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");
    }

    function test_canSpend_succeeds_inDebitMode_whenIncomingDailySpendingLimitRenews() public {
        uint256 amountToSpend = 100e6;
        deal(address(usdcScroll), address(safe), 10 ether);
        _updateSpendingLimit(amountToSpend, 1 ether);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 1;

        Cashback[] memory cashbacks;

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        vm.warp(cashLens.applicableSpendingLimit(address(safe)).dailyRenewalTimestamp + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSpend;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_fails_inDebitMode_whenDailyLimitIsLowerThanAmountUsed() public {
        deal(address(usdcScroll), address(safe), 10 ether);

        uint256 amount = 100e6;

        _updateSpendingLimit(amount - 1, 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Daily available spending limit less than amount requested");
    }

    function test_canSpend_fails_inDebitMode_whenIncomingDailyLimitIsLowerThanAmountUsed() public {
        deal(address(usdcScroll), address(safe), 10 ether);

        uint256 amount = 100e6;
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        _updateSpendingLimit(amount - 1, 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), keccak256("newTxId"), tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Incoming daily spending limit already exhausted");
    }


    function test_canSpend_inputValidation() public view {
        // Test with empty tokens array
        address[] memory tokens = new address[](0);
        uint256[] memory amountsInUsd = new uint256[](0);
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow empty tokens array");
        assertEq(message, "No tokens provided", "Error message should match");
        
        // Test with mismatched array lengths
        tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        amountsInUsd = new uint256[](2);
        amountsInUsd[0] = 1000e6;
        amountsInUsd[1] = 500e6;
        
        (canSpend, message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow mismatched arrays");
        assertEq(message, "Tokens and amounts arrays length mismatch", "Error message should match");
        
        // Test with zero total amount
        tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 0;
        
        (canSpend, message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow zero total amount");
        assertEq(message, "Total amount zero in USD", "Error message should match");
    }

    function test_canSpend_creditModeValidation() public {
        // Set to credit mode
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);
        
        // Try to spend multiple tokens in credit mode
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(weETHScroll);
        uint256[] memory amountsInUsd = new uint256[](2);
        amountsInUsd[0] = 1000e6;
        amountsInUsd[1] = 500e6;
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow multiple tokens in credit mode");
        assertEq(message, "Only one token allowed in Credit mode", "Error message should match");
    }

    function test_canSpend_debitMode() public {
        vm.prank(owner);
        debtManager.supportBorrowToken(address(weETHScroll), borrowApyPerSecond, minShares);        

        // Setup test state with multiple tokens
        deal(address(weETHScroll), address(safe), 5 ether);
        deal(address(usdcScroll), address(safe), 10000e6);
        
        // Try to spend multiple tokens in debit mode
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(weETHScroll);
        uint256[] memory amountsInUsd = new uint256[](2);
        
        // Convert to actual token amounts in USD
        uint256 usdcValueInUsd = debtManager.convertCollateralTokenToUsd(address(usdcScroll), 1000e6);
        uint256 weEthValueInUsd = debtManager.convertCollateralTokenToUsd(address(weETHScroll), 1 ether);
        
        amountsInUsd[0] = usdcValueInUsd;
        amountsInUsd[1] = weEthValueInUsd;
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertTrue(canSpend, "Should allow multiple tokens in debit mode");
        assertEq(message, "", "Error message should be empty");
    }

    function test_canSpend_exceedBalance() public {
        // Setup test state with specific balance
        deal(address(usdcScroll), address(safe), 5000e6);
        
        // Try to spend more than available balance
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = debtManager.convertCollateralTokenToUsd(address(usdcScroll), 10000e6); // More than balance
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow spending more than balance in debit mode");
        assertEq(message, "Insufficient token balance for debit mode spending", "Error message should match");
    }

    function test_canSpend_withWithdrawalRequests() public {
        // Setup test state with collateral
        deal(address(weETHScroll), address(safe), 5 ether);
        deal(address(usdcScroll), address(safe), 10000e6);
        
        // Create a withdrawal request
        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(usdcScroll);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = 5000e6; // Withdraw half of USDC
        _requestWithdrawal(withdrawTokens, withdrawAmounts, withdrawRecipient);
        
        // Try to spend an amount under the remaining balance
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = debtManager.convertCollateralTokenToUsd(address(usdcScroll), 3000e6); // 3000 < (10000-5000)
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, spendTokens, amountsInUsd);
        
        assertTrue(canSpend, "Should allow spending within remaining balance after withdrawal");
        assertEq(message, "", "Error message should be empty");
        
        // Try to spend more than the remaining balance
        amountsInUsd[0] = debtManager.convertCollateralTokenToUsd(address(usdcScroll), 6000e6); // 6000 > (10000-5000)
        
        (canSpend, message) = cashLens.canSpend(address(safe), txId, spendTokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow spending more than remaining balance after withdrawal");
        assertEq(message, "Insufficient effective balance after withdrawal to spend with debit mode", "Error message should match");
    }

    function test_canSpend_exceedsSpendingLimit() public {
        // Setup test state with collateral
        deal(address(usdcScroll), address(safe), 50000e6);
        
        // Set up a smaller spending limit
        _updateSpendingLimit(5000e6, 50000e6); // Daily limit of 5000 USDC
        
        // Try to spend more than daily limit
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 7000e6; // > 5000 daily limit
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow spending more than daily limit");
        assertTrue(bytes(message).length > 0, "Error message should not be empty");
    }

    function test_canSpend_nonBorrowToken() public {
        // Create a mock token that's not a borrow token
        address mockToken = makeAddr("mockToken");
        
        // Try to spend a non-borrow token
        address[] memory tokens = new address[](1);
        tokens[0] = mockToken;
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 1000e6;
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow spending a non-borrow token");
        assertEq(message, "Not a supported stable token", "Error message should match");
    }

    function test_canSpend_alreadyCleared() public {
        // Setup a transaction and mark it as cleared
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        
        deal(address(usdcScroll), address(safe), 10000e6);

        Cashback[] memory cashbacks;

        // Spend to clear the transaction
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amounts, cashbacks);
        
        // Try to spend with the same txId
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 1000e6;
        
        (bool canSpend, string memory message) = cashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        
        assertFalse(canSpend, "Should not allow spending with already cleared txId");
        assertEq(message, "Transaction already cleared", "Error message should match");
    }

    function test_canSpend_fails_whenDuplicateTokensArePassed() public {
        uint256 bal = usdcScroll.balanceOf(address(safe));

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = bal + 1;
        amounts[1] = bal + 1;
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashLens.canSpend(address(safe), txId, tokens, amounts);
    }
    
    function test_canSpendSingleToken_debitMode_firstTokenWorks() public {
        deal(address(usdcScroll), address(safe), 1000e6);
        deal(address(liquidUsdScroll), address(safe), 1000e18);
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](2);
        debitPrefs[0] = address(usdcScroll);
        debitPrefs[1] = address(liquidUsdScroll);
        
        uint256 amountInUsd = 500e6; // 500 USD
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return debit mode");
        assertEq(token, address(usdcScroll), "Should return first preference token");
        assertTrue(canSpend, "Should be able to spend");
        assertEq(message, "", "Should have no error message");
    }

    function test_canSpendSingleToken_debitMode_fallbackToSecondToken() public {
        // Setup: safe only has LiquidUSD
        deal(address(liquidUsdScroll), address(safe), 1000e18);
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](2);
        debitPrefs[0] = address(usdcScroll); // No balance
        debitPrefs[1] = address(liquidUsdScroll); // Has balance
        
        uint256 amountInUsd = 500e6; // 500 USD
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return debit mode");
        assertEq(token, address(liquidUsdScroll), "Should return second preference token");
        assertTrue(canSpend, "Should be able to spend with second token");
        assertEq(message, "", "Should have no error message");
    }

    function test_canSpendSingleToken_creditMode_works() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);
        
        deal(address(weETHScroll), address(safe), 1 ether);
        deal(address(usdcScroll), address(debtManager), 10000e6);
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdcScroll);
        
        uint256 amountInUsd = 500e6; // 500 USD
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Credit), "Should return credit mode");
        assertEq(token, address(usdcScroll), "Should return USDC");
        assertTrue(canSpend, "Should be able to spend in credit mode");
        assertEq(message, "", "Should have no error message");
    }

    function test_canSpendSingleToken_noTokensWork() public {
        deal(address(usdcScroll), address(safe), 100e6);
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](2);
        debitPrefs[0] = address(usdcScroll);
        debitPrefs[1] = address(liquidUsdScroll);
        
        uint256 amountInUsd = 500e6; 
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return debit mode");
        assertEq(token, address(usdcScroll), "Should return first preference token");
        assertFalse(canSpend, "Should not be able to spend");
        assertEq(message, "Insufficient token balance for debit mode spending", "Should return first token's error");
    }

    function test_canSpendSingleToken_emptyPreferences() public view {
        address[] memory creditPrefs = new address[](0);
        address[] memory debitPrefs = new address[](0);
        
        uint256 amountInUsd = 500e6;
        
        (Mode mode, address token, bool canSpend, string memory message) = 
            cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return current mode");
        assertEq(token, address(0), "Should return zero address");
        assertFalse(canSpend, "Should not be able to spend");
        assertEq(message, "No token preferences provided", "Should indicate no preferences");
    }

    function test_canSpendSingleToken_zeroAmount() public view {
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdcScroll);
        
        uint256 amountInUsd = 0; // Zero amount
        
        (Mode mode, address token, bool canSpend, string memory message) = 
            cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return current mode");
        assertEq(token, address(usdcScroll), "Should return first preference");
        assertFalse(canSpend, "Should not be able to spend");
        assertEq(message, "Amount cannot be zero", "Should indicate zero amount");
    }

    function test_canSpendSingleToken_transactionAlreadyCleared() public {
        deal(address(usdcScroll), address(safe), 10000e6);
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        Cashback[] memory cashbacks;
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amounts, cashbacks);
        
        // Try canSpendSingleToken with cleared txId
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdcScroll);
        
        uint256 amountInUsd = 500e6;
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return current mode");
        assertEq(token, address(usdcScroll), "Should return first preference");
        assertFalse(canSpend, "Should not be able to spend");
        assertEq(message, "Transaction already cleared", "Should indicate cleared transaction");
    }

    function test_canSpendSingleToken_withPendingWithdrawals() public {
        // Setup balances
        deal(address(usdcScroll), address(safe), 1000e6);
        deal(address(liquidUsdScroll), address(safe), 1000e18);
        
        // Request withdrawal that affects USDC
        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(usdcScroll);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = 800e6; // Leave only 200 USDC
        _requestWithdrawal(withdrawTokens, withdrawAmounts, withdrawRecipient);
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](2);
        debitPrefs[0] = address(usdcScroll); // Will fail due to withdrawal
        debitPrefs[1] = address(liquidUsdScroll); // Should work
        
        uint256 amountInUsd = 500e6; // More than remaining USDC
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return debit mode");
        assertEq(token, address(liquidUsdScroll), "Should fallback to LiquidUSD");
        assertTrue(canSpend, "Should be able to spend with second token");
        assertEq(message, "", "Should have no error message");
    }

    function test_canSpendSingleToken_creditModeWithInsufficientCollateral() public {
        // Switch to credit mode
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);
        
        // No collateral, but debt manager has liquidity
        deal(address(usdcScroll), address(debtManager), 10000e6);
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdcScroll);
        
        uint256 amountInUsd = 500e6;
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Credit), "Should return credit mode");
        assertEq(token, address(usdcScroll), "Should return USDC");
        assertFalse(canSpend, "Should not be able to spend without collateral");
        assertEq(message, "Insufficient borrowing power", "Should indicate borrowing power issue");
    }

    function test_canSpendSingleToken_spendingLimitExceeded() public {
        // Setup balance
        deal(address(usdcScroll), address(safe), 10000e6);
        
        // Update spending limit to be lower
        _updateSpendingLimit(100e6, 10000e6); // Daily limit of 100 USD
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdcScroll);
        
        uint256 amountInUsd = 200e6; // Exceeds daily limit
        
        (, uint64 spendingLimitDelay,) = cashModule.getDelays();
        vm.warp(block.timestamp + spendingLimitDelay + 1);
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return debit mode");
        assertEq(token, address(usdcScroll), "Should return first preference");
        assertFalse(canSpend, "Should not be able to spend over limit");
        assertEq(message, "Daily available spending limit less than amount requested", "Should indicate limit exceeded");
    }

    function test_canSpendSingleToken_unsupportedTokenInPreferences() public {
        // Setup balance
        deal(address(usdcScroll), address(safe), 1000e6);
        
        address unsupportedToken = makeAddr("unsupportedToken");
        
        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        
        address[] memory debitPrefs = new address[](2);
        debitPrefs[0] = unsupportedToken; // Not a borrow token
        debitPrefs[1] = address(usdcScroll);
        
        uint256 amountInUsd = 500e6;
        
        (Mode mode, address token, bool canSpend, string memory message) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, amountInUsd);
        
        assertEq(uint8(mode), uint8(Mode.Debit), "Should return debit mode");
        assertEq(token, address(usdcScroll), "Should skip unsupported and use USDC");
        assertTrue(canSpend, "Should be able to spend with valid token");
        assertEq(message, "", "Should have no error message");
    }
}
