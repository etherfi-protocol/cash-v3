// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ICashModule, Mode, BinSponsor } from "../../../../src/interfaces/ICashModule.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashModuleSetSettlementDispatcherTest is CashModuleTestSetup {
    function setUp() public override {
        super.setUp();
    }

    function test_setSettlementDispatcher_Rain() public {
        address newDispatcher = makeAddr("newRainDispatcher");
        
        // Store current settlement dispatcher to verify the event
        address oldDispatcher = cashModule.getSettlementDispatcher(BinSponsor.Rain);
        
        // Verify event emission
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.SettlementDispatcheUpdated(BinSponsor.Rain, oldDispatcher, newDispatcher);
        
        // Set new settlement dispatcher
        vm.prank(owner);
        cashModule.setSettlementDispatcher(BinSponsor.Rain, newDispatcher);
        
        // Verify the settlement dispatcher has been updated
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Rain), newDispatcher);
    }
    
    function test_setSettlementDispatcher_Reap() public {
        address newDispatcher = makeAddr("newReapDispatcher");
        
        // Store current settlement dispatcher to verify the event
        address oldDispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        
        // Verify event emission
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.SettlementDispatcheUpdated(BinSponsor.Reap, oldDispatcher, newDispatcher);
        
        // Set new settlement dispatcher
        vm.prank(owner);
        cashModule.setSettlementDispatcher(BinSponsor.Reap, newDispatcher);
        
        // Verify the settlement dispatcher has been updated
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Reap), newDispatcher);
    }
    
    function test_setSettlementDispatcher_failsForNonController() public {
        address newDispatcher = makeAddr("newDispatcher");
        address nonController = makeAddr("nonController");
        
        // Attempt to set new settlement dispatcher with non-controller account
        vm.prank(nonController);
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.setSettlementDispatcher(BinSponsor.Rain, newDispatcher);
    }
    
    function test_setSettlementDispatcher_failsForZeroAddress() public {
        // Attempt to set zero address as settlement dispatcher
        vm.prank(owner);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setSettlementDispatcher(BinSponsor.Rain, address(0));
    }
    
    function test_setSettlementDispatcher_multipleUpdates() public {
        address firstDispatcher = makeAddr("firstDispatcher");
        address secondDispatcher = makeAddr("secondDispatcher");
        
        // First update for Rain
        vm.startPrank(owner);
        cashModule.setSettlementDispatcher(BinSponsor.Rain, firstDispatcher);
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Rain), firstDispatcher);
        
        // Second update for Rain
        cashModule.setSettlementDispatcher(BinSponsor.Rain, secondDispatcher);
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Rain), secondDispatcher);
        
        // First update for Reap
        cashModule.setSettlementDispatcher(BinSponsor.Reap, firstDispatcher);
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Reap), firstDispatcher);
        
        // Second update for Reap
        cashModule.setSettlementDispatcher(BinSponsor.Reap, secondDispatcher);
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Reap), secondDispatcher);
        vm.stopPrank();
    }
    
    function test_setSettlementDispatcher_spendWithNewDispatcher() public {
        // Configure a new settlement dispatcher for Reap
        address newDispatcher = makeAddr("newReapDispatcher");
        vm.prank(owner);
        cashModule.setSettlementDispatcher(BinSponsor.Reap, newDispatcher);
        
        // Verify the settlement dispatcher has been updated
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Reap), newDispatcher);
        
        // Setup a spend transaction
        uint256 spendAmountInUsd = 50e6; // $50 in USDC
        uint256 tokenAmount = debtManager.convertUsdToCollateralToken(address(usdcScroll), spendAmountInUsd);
        
        // Fund the safe
        deal(address(usdcScroll), address(safe), tokenAmount);
        
        // Prepare spend parameters
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmountInUsd;
        
        // Track initial balance of the new dispatcher
        uint256 dispatcherBalanceBefore = usdcScroll.balanceOf(newDispatcher);
        
        // Execute spend to verify tokens go to the new dispatcher
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);
        
        // Verify tokens were transferred to the new settlement dispatcher
        assertEq(usdcScroll.balanceOf(address(safe)), 0);
        assertEq(usdcScroll.balanceOf(newDispatcher), dispatcherBalanceBefore + tokenAmount);
        
        // Original settlement dispatcher should not have received tokens
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), 0);
    }
    
    function test_setSettlementDispatcher_differentDispatchersForDifferentBinSponsors() public {
        address rainDispatcher = makeAddr("rainDispatcher");
        address reapDispatcher = makeAddr("reapDispatcher");
        
        // Set different dispatchers for each bin sponsor
        vm.startPrank(owner);
        cashModule.setSettlementDispatcher(BinSponsor.Rain, rainDispatcher);
        cashModule.setSettlementDispatcher(BinSponsor.Reap, reapDispatcher);
        vm.stopPrank();
        
        // Verify dispatchers were set correctly
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Rain), rainDispatcher);
        assertEq(cashModule.getSettlementDispatcher(BinSponsor.Reap), reapDispatcher);
        
        // Setup a spend transaction
        uint256 spendAmountInUsd = 50e6; // $50 in USDC
        uint256 tokenAmount = debtManager.convertUsdToCollateralToken(address(usdcScroll), spendAmountInUsd);
        
        // Fund the safe
        deal(address(usdcScroll), address(safe), tokenAmount * 2); // Fund enough for two transactions
        
        // Prepare spend parameters
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmountInUsd;
        
        // Track initial balances
        uint256 rainDispatcherBalanceBefore = usdcScroll.balanceOf(rainDispatcher);
        uint256 reapDispatcherBalanceBefore = usdcScroll.balanceOf(reapDispatcher);
        
        // Execute spend with Rain bin sponsor
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Rain, spendTokens, spendAmounts, true);
        
        // Verify tokens went to Rain dispatcher
        assertEq(usdcScroll.balanceOf(rainDispatcher), rainDispatcherBalanceBefore + tokenAmount);
        assertEq(usdcScroll.balanceOf(reapDispatcher), reapDispatcherBalanceBefore); // No change
        
        // Execute another spend with Reap bin sponsor
        bytes32 txId2 = keccak256("txId2");
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId2, BinSponsor.Reap, spendTokens, spendAmounts, true);
        
        // Verify tokens went to Reap dispatcher
        assertEq(usdcScroll.balanceOf(rainDispatcher), rainDispatcherBalanceBefore + tokenAmount); // No change
        assertEq(usdcScroll.balanceOf(reapDispatcher), reapDispatcherBalanceBefore + tokenAmount);
    }
}