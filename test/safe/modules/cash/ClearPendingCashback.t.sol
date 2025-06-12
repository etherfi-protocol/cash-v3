// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Test } from "forge-std/Test.sol";

import { ICashModule, BinSponsor, Mode, Cashback, CashbackTokens, CashbackTypes } from "../../../../src/interfaces/ICashModule.sol";
import { ICashbackDispatcher } from "../../../../src/interfaces/ICashbackDispatcher.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import { UpgradeableProxy } from "../../../../src/utils/UpgradeableProxy.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";

contract CashModuleClearPendingCashbackTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;
    
    address user1;
    address user2;
    address user3;

    address[] tokens;
    
    function setUp() public override {
        super.setUp();
        
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        tokens.push(address(scrToken));
    }

    function test_clearPendingCashback_reverts_whenEmptyArray() public {
        // Test with an empty array, should execute without reverting
        address[] memory users = new address[](0);
        
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.clearPendingCashback(users, tokens);
    }
    
    
    function test_clearPendingCashback_reverts_whenArrayContainsDuplicates() public {
        // Test with an empty array, should execute without reverting
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user1;
        
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashModule.clearPendingCashback(users);
    }
    
    function test_clearPendingCashback_ZeroAddress() public {
        // Create array with zero address
        address[] memory users = new address[](1);
        users[0] = address(0);
        
        // Should revert with InvalidInput
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.clearPendingCashback(users, tokens);
    }
    
    function test_clearPendingCashback_WhenPaused() public {
        // Setup array of users
        address[] memory users = new address[](1);
        users[0] = user1;
        
        // Pause the contract
        vm.prank(pauser);
        UpgradeableProxy(address(cashModule)).pause();
        
        // Call should revert when paused
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cashModule.clearPendingCashback(users, tokens);
        
        // Unpause
        vm.prank(unpauser);
        UpgradeableProxy(address(cashModule)).unpause();
        
        // Should work again after unpausing
        cashModule.clearPendingCashback(users, tokens);
    }
    
    function test_clearPendingCashback_MultipleUsers() public {
        // Create array with multiple users
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        
        // Setup some pending cashback internally (this is difficult to do directly)
        // Instead, we'll use spend operations with failed cashback to create pending cashback
        
        uint256 spendAmount = 100e6;
        deal(address(usdcScroll), address(safe), spendAmount * 3); // Enough for all operations
        deal(address(scrToken), address(cashbackDispatcher), 0); 

        // Perform spend for each user to create pending cashback
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;
        
        for (uint i = 0; i < users.length; i++) {
            Cashback[] memory cashbacks = new Cashback[](1);
            CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

            CashbackTokens memory scrSafe = CashbackTokens({
                token: address(scrToken),
                amountInUsd: 1e6,
                cashbackType: CashbackTypes.Regular
            });
            cashbackTokens[0] = scrSafe;
            Cashback memory scrCashbackUser = Cashback({
                to: address(users[i]),
                cashbackTokens: cashbackTokens
            });

            cashbacks[0] = scrCashbackUser;

            vm.prank(etherFiWallet);
            cashModule.spend(address(safe), keccak256(abi.encodePacked("spend", i)), BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        }
        
        // Verify pending cashback exists for the users
        for (uint i = 0; i < users.length; i++) {
            assertGt(cashModule.getPendingCashbackForToken(users[i], address(scrToken)), 0);
        }

        uint256[] memory balancesBefore = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) balancesBefore[i] = scrToken.balanceOf(users[i]);

        deal(address(scrToken), address(cashbackDispatcher), 1000 ether); 
        
        cashModule.clearPendingCashback(users, tokens);
        
        for (uint256 i = 0; i < users.length; i++) assertGt(scrToken.balanceOf(users[i]), balancesBefore[i]);
    }
    
    function test_clearPendingCashback_DuplicateUsers() public {
        // Create array with duplicate users
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user1; // Duplicate
        users[2] = user1; // Duplicate
        
        // Setup pending cashback for user1
        uint256 spendAmount = 100e6;
        deal(address(usdcScroll), address(safe), spendAmount);
        deal(address(scrToken), address(cashbackDispatcher), 0);
        
        // Create pending cashback
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scrSafe = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });
        cashbackTokens[0] = scrSafe;
        Cashback memory scrCashbackUser = Cashback({
            to: address(user1),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashbackUser;
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("spend"), BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Verify pending cashback exists
        assertGt(cashModule.getPendingCashbackForToken(user1, address(scrToken)), 0);
        
        deal(address(scrToken), address(cashbackDispatcher), 1000 ether);
        
        cashModule.clearPendingCashback(users, tokens);
    }
    
    function test_clearPendingCashback_NoPendingCashback() public {
        // Test with user who has no pending cashback
        address[] memory users = new address[](1);
        users[0] = user1;
        
        // // Setup mock for unsuccessful cashback clearance (no pending cashback)
        // vm.mockCall(
        //     address(cashbackDispatcher),
        //     abi.encodeWithSelector(cashbackDispatcher.clearPendingCashback.selector, user1, tokens),
        //     abi.encode(0, false)
        // );

        uint256 balBefore = scrToken.balanceOf(user1);
        
        // Should execute without errors and emit no events
        cashModule.clearPendingCashback(users, tokens);

        assertEq(scrToken.balanceOf(user1), balBefore);
    }
    
    function test_clearPendingCashback_AfterSpend() public {
        // Test clearing pending cashback immediately after a spend operation
        uint256 spendAmount = 100e6;
        deal(address(usdcScroll), address(safe), spendAmount);
        deal(address(scrToken), address(cashbackDispatcher), 0);

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scrSafe = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });
        cashbackTokens[0] = scrSafe;
        Cashback memory scrCashbackUser = Cashback({
            to: address(user1),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashbackUser;

        // Perform spend to create pending cashback
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmount;
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Verify pending cashback was created
        uint256 pendingCashback = cashModule.getPendingCashbackForToken(user1, address(scrToken));
        assertGt(pendingCashback, 0);

        deal(address(scrToken), address(cashbackDispatcher), 1000 ether);
        
        // Clear pending cashback
        address[] memory users = new address[](1);
        users[0] = user1;
                
        cashModule.clearPendingCashback(users, tokens);
        
        // Verify pending cashback was cleared
        assertEq(cashModule.getPendingCashbackForToken(user1, address(scrToken)), 0);
    }
}