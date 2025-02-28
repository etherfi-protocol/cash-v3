// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { CashModule, SpendingLimitLib } from "../../../../src/modules/cash/CashModule.sol";
import { ICashDataProvider } from "../../../../src/interfaces/ICashDataProvider.sol";
import { ICashModule, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, EtherFiDataProvider } from "../../SafeTestSetup.t.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import {CashVerificationLib} from "../../../../src/libraries/CashVerificationLib.sol";

contract SpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_spend_works_inDebitMode() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(settlementDispatcher);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), amount);
        
        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId")));
        
        // Verify tokens were transferred to settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), 0);
        assertEq(usdcScroll.balanceOf(settlementDispatcher), settlementDispatcherBalBefore + amount);
    }
    
    function test_spend_reverts_whenTransactionAlreadyCleared() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        // Mark transaction as cleared
        bytes32 txId = keccak256("txId");
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, address(usdcScroll), amount);
        
        // Try to spend again with the same txId
        vm.prank(etherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(CashModule.TransactionAlreadyCleared.selector));
        cashModule.spend(address(safe), txId, address(usdcScroll), amount);
    }
    
    function test_spend_reverts_whenUnsupportedToken() public {
        // Setup mock token that is not a borrow token
        address mockToken = makeAddr("mockToken");

        vm.prank(etherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(CashModule.UnsupportedToken.selector));
        cashModule.spend(address(safe), keccak256("txId"), mockToken, 100e6);
    }
    
    function test_spend_reverts_whenAmountIsZero() public {        
        vm.prank(etherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(CashModule.AmountZero.selector));
        cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), 0);
    }
    
    function test_spend_reverts_whenNotEtherFiWallet() public {
        address notEtherFiWallet = makeAddr("notEtherFiWallet");
        
        vm.prank(notEtherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(CashModule.OnlyEtherFiWallet.selector));
        cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), 100e6);
    }
    
    function test_spend_worksWithPendingWithdrawal() public {
        uint256 initialAmount = 200e6;
        uint256 spendAmount = 100e6;
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), initialAmount);
        
        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;
        
        address recipient = address(owner1);
        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(settlementDispatcher);

        bytes memory signature = _requestWithdrawal(tokens, amounts, recipient);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, owner1, signature);
        
        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);
        
        // Spend should work and account for the pending withdrawal
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), spendAmount);
        
        // Verify tokens were transferred
        assertEq(usdcScroll.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdcScroll.balanceOf(settlementDispatcher), settlementDispatcherBalBefore + spendAmount);
        
        // Verify pending withdrawal still exists
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);
    }
    
    function test_spend_updatesWithdrawalRequestIfNecessary() public {
        uint256 initialAmount = 200e6;
        uint256 spendAmount = 150e6;
        uint256 withdrawalAmount = 100e6;
        deal(address(usdcScroll), address(safe), initialAmount);
        
        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;
        
        address recipient = address(owner1);

        uint256 settlementDispatcherBalBefore = usdcScroll.balanceOf(settlementDispatcher);

        bytes memory signature = _requestWithdrawal(tokens, amounts, recipient);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, owner1, signature);        
        
        // Spend should work and cancel the withdrawal
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), spendAmount);
        
        // Verify tokens were transferred
        assertEq(usdcScroll.balanceOf(address(safe)), initialAmount - spendAmount);
        assertEq(usdcScroll.balanceOf(settlementDispatcher), settlementDispatcherBalBefore + spendAmount);
        
        // Verify pending withdrawal was cancelled
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), initialAmount - spendAmount);
    }
    
    function test_spend_respectsSpendingLimits() public {
        deal(address(usdcScroll), address(safe), 1e12);
                
        // Try to spend more than daily limit
        vm.prank(etherFiWallet);
        vm.expectRevert(SpendingLimitLib.ExceededDailySpendingLimit.selector); 
        cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), dailyLimitInUsd + 1);
        
        // Spend within limit should work
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId2"), address(usdcScroll), dailyLimitInUsd / 2);
        
        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId2")));
    }
    
    
    function _requestWithdrawal(address[] memory tokens, uint256[] memory amounts, address recipient) internal returns (bytes memory) {
        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                CashVerificationLib.REQUEST_WITHDRAWAL_METHOD,
                block.chainid,
                address(safe),
                nonce,
                abi.encode(tokens, amounts, recipient)
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            owner1Pk,
            msgHash.toEthSignedMessageHash()
        );

        /// TODO: Remove this when debt manager is upgraded
        vm.mockCall(
            address(debtManager),
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)),
            abi.encode()
        );

        bytes memory signature = abi.encodePacked(r, s, v);
        return signature;
    }}