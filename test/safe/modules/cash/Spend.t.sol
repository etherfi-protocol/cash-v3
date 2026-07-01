// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { ICashModule, Mode, BinSponsor, Cashback, CashbackTokens } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IGateway } from "../../../../src/interfaces/IGateway.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { SpendingLimitLib } from "../../../../src/libraries/SpendingLimitLib.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import { UpgradeableProxy } from "../../../../src/utils/UpgradeableProxy.sol";

contract CashModuleSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_spend_works_inDebitMode() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        uint256 settlementDispatcherBalBefore = usdc.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Debit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherBalBefore + amount);
    }

    function test_spend_worksWithMultipleToken_inDebitMode() public {
        vm.prank(owner);
        debtManager.supportBorrowToken(address(weETH), borrowApyPerSecond, minShares);

        uint256 amountInUsd = 100e6;
        uint256 totalAmountInUsd = amountInUsd * 2; // Pre-calculate total
        uint256 usdcAmount = debtManager.convertUsdToCollateralToken(address(usdc), amountInUsd);
        uint256 weETHAmount = debtManager.convertUsdToCollateralToken(address(weETH), amountInUsd);

        deal(address(usdc), address(safe), usdcAmount);
        deal(address(weETH), address(safe), weETHAmount);

        uint256 settlementDispatcherUsdcBalBefore = usdc.balanceOf(address(settlementDispatcherReap));
        uint256 settlementDispatcherWeETHBalBefore = weETH.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = amountInUsd;
        spendAmounts[1] = amountInUsd;

        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = usdcAmount;
        tokenAmounts[1] = weETHAmount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, tokenAmounts, spendAmounts, totalAmountInUsd, Mode.Debit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(weETH.balanceOf(address(safe)), 0);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherUsdcBalBefore + usdcAmount);
        assertEq(weETH.balanceOf(address(settlementDispatcherReap)), settlementDispatcherWeETHBalBefore + weETHAmount);
    }

    function test_spend_works_inCreditMode() public {
        uint256 initialBalance = 100e6;
        deal(address(usdc), address(safe), initialBalance);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Credit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Credit borrows via the gateway; the safe's own balance is untouched and the borrow is forwarded to the dispatcher
        assertEq(usdc.balanceOf(address(safe)), initialBalance);

        (address s, address asset, uint256 amt, address to) = gateway.lastBorrow();
        assertEq(s, address(safe));
        assertEq(asset, address(usdc));
        assertEq(amt, amount);
        assertEq(to, address(settlementDispatcherReap));
    }

    function test_spend_failsWithMultipleTokens_inCreditMode() public {
        uint256 initialBalance = 100e6;
        deal(address(usdc), address(safe), initialBalance);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = amount;
        spendAmounts[1] = amount;
        
        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.OnlyOneTokenAllowedInCreditMode.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_reverts_whenTransactionAlreadyCleared() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        // Mark transaction as cleared
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Try to spend again with the same txId
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.TransactionAlreadyCleared.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_reverts_whenUnsupportedToken() public {
        // Setup mock token that is not a borrow token
        address mockToken = makeAddr("mockToken");

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = mockToken;
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 100e6;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.UnsupportedToken.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_reverts_whenAmountIsZero() public {
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 0;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.AmountZero.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_reverts_whenNotEtherFiWallet() public {
        address notEtherFiWallet = makeAddr("notEtherFiWallet");

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 100e6;

        Cashback[] memory cashbacks;

        vm.prank(notEtherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(ICashModule.OnlyEtherFiWallet.selector));
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_worksWithPendingWithdrawalInDebitMode() public {
        uint256 initialAmount = 200e6;
        uint256 spendAmount = 100e6;
        uint256 withdrawalAmount = 50e6;
        deal(address(usdc), address(safe), initialAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 settlementDispatcherBalBefore = usdc.balanceOf(address(settlementDispatcherReap));

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), withdrawalAmount);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;

        Cashback[] memory cashbacks;

        // Spend should work and account for the pending withdrawal
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify tokens were transferred
        assertEq(usdc.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherBalBefore + spendAmount);

        // Verify pending withdrawal still exists
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), withdrawalAmount);
    }

    // A failed gateway borrow propagates and reverts the whole credit spend (the old catch-and-retry is gone).
    function test_spend_reverts_whenCreditBorrowBlocked() public {
        deal(address(usdc), address(safe), 100e6);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 10e6;

        Cashback[] memory cashbacks;

        // The gateway rejects the borrow, which bubbles up and reverts the spend.
        gateway.setBorrowReverts(true);

        vm.prank(etherFiWallet);
        vm.expectRevert(bytes("MockGateway: borrow blocked"));
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_cancelsWithdrawalRequestIfNecessary() public {
        uint256 initialAmount = 200e6;
        uint256 spendAmount = 150e6;
        uint256 withdrawalAmount = 100e6;
        deal(address(usdc), address(safe), initialAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 settlementDispatcherBalBefore = usdc.balanceOf(address(settlementDispatcherReap));

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;

        Cashback[] memory cashbacks;

        // Spend should work and cancel the withdrawal
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify tokens were transferred
        assertEq(usdc.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherBalBefore + spendAmount);

        // Verify pending withdrawal was cancelled
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), 0);
    }

    function test_spend_respectsSpendingLimits() public {
        deal(address(usdc), address(safe), 1e12);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = dailyLimitInUsd + 1;

        Cashback[] memory cashbacks;

        // Try to spend more than daily limit
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        spendAmounts[0] = dailyLimitInUsd / 2;

        // Spend within limit should work
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId2"), BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId2")));
    }

    function test_spend_inDebitMode_fails_whenBorrowExceedsMaxBorrow() public {
        uint256 amount = 100e6;

        // No loose balance: the spend must withdraw the whole amount from the Aave-supplied position.
        gateway.setSuppliedOf(address(safe), address(usdc), amount);
        gateway.setAvailableCash(address(usdc), type(uint128).max);

        // Seed the post-withdrawal position at its borrowing limit (headroom 0 with debt outstanding), so
        // withdrawing collateral for the spend leaves the safe over its LTV-based max borrow.
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 200e6, debtUsd: 100e6, availableBorrowsUsd: 0, healthFactor: 1e18 }));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.BorrowingsExceedMaxBorrowAfterSpending.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_spend_inDebitMode_looseOnlySpendAllowed_whenOverBorrowLimit() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        // Safe is already over its LTV-based borrow limit (headroom 0 with debt), e.g. after a price drop.
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 200e6, debtUsd: 100e6, availableBorrowsUsd: 0, healthFactor: 1e18 }));

        uint256 dispatcherBalBefore = usdc.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        // Sourced entirely from loose balance, so it does not touch Aave and is allowed despite the
        // exhausted borrow headroom.
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBalBefore + amount);
        (address withdrawnSafe,,,) = gateway.lastWithdraw();
        assertEq(withdrawnSafe, address(0)); // no gateway withdrawal happened
    }

    function test_spend_inDebitMode_drawsLooseThenWithdrawsSupplied() public {
        uint256 loose = 40e6;
        uint256 supplied = 100e6;
        uint256 spendAmount = 100e6; // 40 from the loose balance, 60 withdrawn from the Aave-supplied balance

        deal(address(usdc), address(safe), loose);
        gateway.setSuppliedOf(address(safe), address(usdc), supplied);
        gateway.setAvailableCash(address(usdc), type(uint128).max);

        uint256 dispatcherBalBefore = usdc.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Loose balance spent directly to the dispatcher
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBalBefore + loose);

        // Shortfall withdrawn from the Aave-supplied balance to the dispatcher via the gateway
        (address s, address asset, uint256 amt, address to) = gateway.lastWithdraw();
        assertEq(s, address(safe));
        assertEq(asset, address(usdc));
        assertEq(amt, spendAmount - loose);
        assertEq(to, address(settlementDispatcherReap));
    }

    function test_spend_reverts_whenArrayLengthMismatch() public {
        // Create mismatched arrays
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(weETH);
        
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 100e6;

        Cashback[] memory cashbacks;
        
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.ArrayLengthMismatch.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }
    
    function test_spend_reverts_whenEmptyTokensArray() public {
        // Create empty tokens array
        address[] memory spendTokens = new address[](0);
        uint256[] memory spendAmounts = new uint256[](0);

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }
    
    function test_spend_withNoCashback() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        // Get initial cashback token balances
        uint256 safeCashbackBalBefore = cashbackToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        // Spend with shouldReceiveCashback set to false
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify no cashback was received
        assertEq(cashbackToken.balanceOf(address(safe)), safeCashbackBalBefore);
    }
    
    function test_spend_whenPaused() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        
        // Pause the contract
        vm.prank(pauser);
        UpgradeableProxy(address(cashModule)).pause();

        Cashback[] memory cashbacks;
        
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
    
    function test_spend_multiplesWithinLimits() public {
        uint256 smallAmount = dailyLimitInUsd / 5;
        deal(address(usdc), address(safe), 1 ether);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);

        Cashback[] memory cashbacks;
        
        // Perform multiple spends
        for (uint i = 0; i < 4; i++) {
            spendAmounts[0] = smallAmount;
            bytes32 currentTxId = keccak256(abi.encodePacked("txId", i));
            
            vm.prank(etherFiWallet);
            cashModule.spend(address(safe), currentTxId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        }
        
        // This spend should exceed the daily limit
        spendAmounts[0] = smallAmount + 1;
        bytes32 finalTxId = keccak256(abi.encodePacked("txId-final"));
        
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector);
        cashModule.spend(address(safe), finalTxId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Advance time to next day (considering timezone offset)
        uint256 timeToAdd = 24 hours;
        vm.warp(block.timestamp + timeToAdd);
        
        // Now the spend should work as daily limit resets
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), finalTxId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }
        
    function test_spend_inDebitModeWithInsufficientBalance() public {
        uint256 amount = 100e6;
        uint256 availableAmount = 50e6;
        deal(address(usdc), address(safe), availableAmount);
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;
        
        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_settlementDispatcherView() public view {
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Reap), address(settlementDispatcherReap));
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Rain), address(settlementDispatcherRain));
    }

    function test_spend_FundsGoToBinSponsorSettlementDispatcherAsSpecified_inDebitMode() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), 2 * amount);

        uint256 settlementDispatcherReapBalBefore = usdc.balanceOf(address(settlementDispatcherReap));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Debit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdc.balanceOf(address(safe)), amount);
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), settlementDispatcherReapBalBefore + amount);

        uint256 settlementDispatcherRainBalBefore = usdc.balanceOf(address(settlementDispatcherRain));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Debit);
        cashModule.spend(address(safe), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId2")));

        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(usdc.balanceOf(address(settlementDispatcherRain)), settlementDispatcherRainBalBefore + amount);
    }

    function test_spend_FundsGoToBinSponsorSettlementDispatcherAsSpecified_inCreditMode() public {
        uint256 initialBalance = 100e6;
        deal(address(usdc), address(safe), initialBalance);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Credit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), txId));

        // Credit borrows via the gateway and forwards the Reap borrow to the Reap dispatcher
        assertEq(usdc.balanceOf(address(safe)), initialBalance);

        (address sReap, address assetReap, uint256 amtReap, address toReap) = gateway.lastBorrow();
        assertEq(sReap, address(safe));
        assertEq(assetReap, address(usdc));
        assertEq(amtReap, amount);
        assertEq(toReap, address(settlementDispatcherReap));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Credit);
        cashModule.spend(address(safe), keccak256("txId2"), BinSponsor.Rain, spendTokens, spendAmounts, cashbacks);

        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId2")));

        // The Rain borrow is forwarded to the Rain dispatcher
        assertEq(usdc.balanceOf(address(safe)), initialBalance);

        (address sRain, address assetRain, uint256 amtRain, address toRain) = gateway.lastBorrow();
        assertEq(sRain, address(safe));
        assertEq(assetRain, address(usdc));
        assertEq(amtRain, amount);
        assertEq(toRain, address(settlementDispatcherRain));
    }

    function test_spend_fails_whenDuplicateTokensArePassed() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](2);
        spendAmounts[0] = amount;
        spendAmounts[1] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }
}
