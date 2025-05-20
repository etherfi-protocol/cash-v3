// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../../src/oracle/PriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { SettlementDispatcher } from "../../../../../src/settlement-dispatcher/SettlementDispatcher.sol";

contract SettlementDispatcherTest is CashModuleTestSetup {
    address alice = makeAddr("alice");

    address liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address boringQueueLiquidUsd = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
    uint16 discount = 1;
    uint24 secondsToDeadline = 3 days;

    address refundWallet = makeAddr("refundWallet");
    address newRefundWallet = makeAddr("newRefundWallet");

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.LiquidWithdrawConfigSet(liquidUsd, address(usdcScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(liquidUsd, address(usdcScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
    }

    function test_setRefundWallet_succeeds_whenCalledByOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.RefundWalletSet(address(0), refundWallet);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        assertEq(settlementDispatcherReap.getRefundWallet(), refundWallet);
    }

    function test_setRefundWallet_succeeds_whenChangingExistingWallet() public {
        // First set initial wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Then change it
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.RefundWalletSet(refundWallet, newRefundWallet);
        settlementDispatcherReap.setRefundWallet(newRefundWallet);
        
        assertEq(settlementDispatcherReap.getRefundWallet(), newRefundWallet);
    }

    function test_setRefundWallet_reverts_whenCallerNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        settlementDispatcherReap.setRefundWallet(refundWallet);
    }

    function test_setRefundWallet_reverts_whenAddressZero() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setRefundWallet(address(0));
    }

    function test_getRefundWallet_returnsCorrectAddress() public {
        // Initially should be address(0)
        assertEq(settlementDispatcherReap.getRefundWallet(), address(0));
        
        // Set refund wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Should return the set address
        assertEq(settlementDispatcherReap.getRefundWallet(), refundWallet);
    }

    function test_transferFundsToRefundWallet_succeeds_withErc20Token() public {
        // Set refund wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Fund the contract with USDC
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(settlementDispatcherReap), amount);
        
        // Track balances before transfer
        uint256 walletBalBefore = usdcScroll.balanceOf(refundWallet);
        uint256 dispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));
        
        // Transfer funds
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.TransferToRefundWallet(address(usdcScroll), refundWallet, amount);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), amount);
        
        // Check balances after transfer
        uint256 walletBalAfter = usdcScroll.balanceOf(refundWallet);
        uint256 dispatcherBalAfter = usdcScroll.balanceOf(address(settlementDispatcherReap));
        
        assertEq(walletBalAfter - walletBalBefore, amount);
        assertEq(dispatcherBalBefore - dispatcherBalAfter, amount);
    }

    function test_transferFundsToRefundWallet_succeeds_withNativeToken() public {
        // Set refund wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Fund the contract with ETH
        uint256 amount = 1 ether;
        deal(address(settlementDispatcherReap), amount);
        
        // Track balances before transfer
        uint256 walletBalBefore = refundWallet.balance;
        uint256 dispatcherBalBefore = address(settlementDispatcherReap).balance;
        
        // Transfer funds
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.TransferToRefundWallet(address(0), refundWallet, amount);
        settlementDispatcherReap.transferFundsToRefundWallet(address(0), amount);
        
        // Check balances after transfer
        uint256 walletBalAfter = refundWallet.balance;
        uint256 dispatcherBalAfter = address(settlementDispatcherReap).balance;
        
        assertEq(walletBalAfter - walletBalBefore, amount);
        assertEq(dispatcherBalBefore - dispatcherBalAfter, amount);
    }

    function test_transferFundsToRefundWallet_transferAllTokens_withAmountZero() public {
        // Set refund wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Fund the contract with USDC
        uint256 totalAmount = 100e6;
        deal(address(usdcScroll), address(settlementDispatcherReap), totalAmount);
        
        // Track balances before transfer
        uint256 walletBalBefore = usdcScroll.balanceOf(refundWallet);
        uint256 dispatcherBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));
        
        // Transfer funds with amount 0 (should transfer all tokens)
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.TransferToRefundWallet(address(usdcScroll), refundWallet, totalAmount);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), 0);
        
        // Check balances after transfer
        uint256 walletBalAfter = usdcScroll.balanceOf(refundWallet);
        uint256 dispatcherBalAfter = usdcScroll.balanceOf(address(settlementDispatcherReap));
        
        assertEq(walletBalAfter - walletBalBefore, totalAmount);
        assertEq(dispatcherBalBefore - dispatcherBalAfter, totalAmount);
        assertEq(dispatcherBalAfter, 0);
    }

    function test_transferFundsToRefundWallet_reverts_whenNoBalanceAndAmountIsZero() public {
        // Set refund wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Attempt to transfer with zero balance
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.CannotWithdrawZeroAmount.selector);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), 0);
    }


    function test_transferFundsToRefundWallet_reverts_whenRefundWalletNotSet() public {
        // Don't set refund wallet
        
        // Fund the contract
        deal(address(usdcScroll), address(settlementDispatcherReap), 100e6);
        
        // Attempt to transfer
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.RefundWalletNotSet.selector);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), 100e6);
    }

    function test_transferFundsToRefundWallet_reverts_whenCallerNotBridger() public {
        // Set refund wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Fund the contract
        deal(address(usdcScroll), address(settlementDispatcherReap), 100e6);
        
        // Attempt to transfer as non-bridger
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), 100e6);
    }

    function test_transferFundsToRefundWallet_reverts_whenInsufficientBalance() public {
        // Set refund wallet
        vm.prank(owner);
        settlementDispatcherReap.setRefundWallet(refundWallet);
        
        // Fund the contract with less than we'll try to transfer
        uint256 amount = 50e6;
        deal(address(usdcScroll), address(settlementDispatcherReap), amount);
        
        // Attempt to transfer more than available
        vm.prank(owner);
        vm.expectRevert();
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), amount * 2);
    }

    function test_setLiquidAssetWithdrawConfig_setsTheConfig() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.LiquidWithdrawConfigSet(liquidUsd, address(usdcScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(liquidUsd, address(usdcScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
    }
    
    function test_setLiquidAssetWithdrawConfig_fails_ifSetterNotRoleRegistryOwner() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(liquidUsd, address(usdcScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
    }

    function test_setLiquidAssetWithdrawConfig_fails_ifBoringQueueIsNotCorrect() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InvalidBoringQueue.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(address(usdcScroll), address(usdcScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
    }
    
    function test_setLiquidAssetWithdrawConfig_fails_ForZeroAddresses() public {
        vm.startPrank(owner);
        
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(address(0), address(usdcScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
        
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(liquidUsd, address(0), address(boringQueueLiquidUsd), discount, secondsToDeadline);
        
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(liquidUsd, address(usdcScroll), address(0), discount, secondsToDeadline);

        vm.stopPrank();
    }
    
    function test_setLiquidAssetWithdrawConfig_fails_ifAssetOutNotSupported() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.BoringQueueDoesNotAllowAssetOut.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(address(boringQueueLiquidUsd), address(weETHScroll), address(boringQueueLiquidUsd), discount, secondsToDeadline);
    }
    
    function test_setLiquidAssetWithdrawConfig_fails_ifDiscountOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InvalidDiscount.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(address(boringQueueLiquidUsd), address(usdcScroll), address(boringQueueLiquidUsd), 1e4, secondsToDeadline);
    }

    function test_setLiquidAssetWithdrawConfig_fails_ifSecondsToDeadlineIsLessThanMin() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.SecondsToDeadlingLowerThanMin.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawConfig(address(boringQueueLiquidUsd), address(usdcScroll), address(boringQueueLiquidUsd), discount, 1);
    }

    function test_withdrawLiquidAsset_succeeds() public {
        uint128 amount = 100e6;

        deal(liquidUsd, address(settlementDispatcherReap), amount);
    
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.LiquidWithdrawalRequested(liquidUsd, address(usdcScroll), amount);
        settlementDispatcherReap.withdrawLiquidAsset(liquidUsd, amount);

        assertEq(IERC20(liquidUsd).balanceOf(address(settlementDispatcherReap)), 0);
    }

    function test_withdrawLiquidAsset_fails_ifConfigNotSet() public {
        uint128 amount = 100e6;

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.LiquidWithdrawConfigNotSet.selector);
        settlementDispatcherReap.withdrawLiquidAsset(address(usdcScroll), amount);
    }

    function test_setDestinationData_succeeds_whenCalledByAdmin() public {
        (address[] memory tokens, SettlementDispatcher.DestinationData[] memory destDatas) = getDestData();
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.DestinationDataSet(tokens, destDatas);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);

        SettlementDispatcher.DestinationData memory destData = settlementDispatcherReap.destinationData(address(usdcScroll));

        assertEq(destData.destEid, optimismDestEid);
        assertEq(destData.destRecipient, alice);
        assertEq(destData.stargate, stargateUsdcPool);
    }

    function test_setDestinationData_reverts_whenCallerNotAdmin() public {
        (address[] memory tokens, SettlementDispatcher.DestinationData[] memory destDatas) = getDestData();

        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);
    }

    function test_setDestinationData_reverts_whenArrayLengthMismatch() public {
        address[] memory tokens = new address[](2);
        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.ArrayLengthMismatch.selector);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);
    }

    function test_setDestinationData_reverts_whenInvalidValueProvided() public {
        (address[] memory tokens, SettlementDispatcher.DestinationData[] memory destDatas) = getDestData();

        vm.startPrank(owner);
        tokens[0] = address(0);

        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);

        tokens[0] = address(usdcScroll);
        destDatas[0].destRecipient = address(0);

        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);

        destDatas[0].destRecipient = alice;
        destDatas[0].stargate = address(0);

        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);
        vm.stopPrank();
    }

    function test_setDestinationData_reverts_whenInvalidStargateValue() public {
        (address[] memory tokens, SettlementDispatcher.DestinationData[] memory destDatas) = getDestData();

        vm.startPrank(owner);
        destDatas[0].stargate = stargateEthPool;
        vm.expectRevert(SettlementDispatcher.StargateValueInvalid.selector);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);
        vm.stopPrank();
    }

    function test_bridge_succeeds_whenCalledByBridger() public {
        uint256 balBefore = 100e6;
        deal(address(usdcScroll), address(settlementDispatcherReap), balBefore);
        
        uint256 amount = 10e6;
        ( , uint256 valueToSend, , , ) = settlementDispatcherReap.prepareRideBus(address(usdcScroll), amount);

        deal(address(settlementDispatcherReap), valueToSend);
        
        uint256 stargateBalBefore = usdcScroll.balanceOf(address(stargateUsdcPool));

        vm.prank(owner);
        settlementDispatcherReap.bridge(address(usdcScroll), amount, 1);

        uint256 stargateBalAfter = usdcScroll.balanceOf(address(stargateUsdcPool));

        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), balBefore - amount);
        assertEq(stargateBalAfter - stargateBalBefore, amount);
    }

    function test_bridge_reverts_whenCallerNotBridger() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        settlementDispatcherReap.bridge(address(usdcScroll), 1, 1);
    }

    function test_bridge_reverts_whenInvalidParametersProvided() public {
        vm.startPrank(owner);
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.bridge(address(0), 1, 1);
        
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.bridge(address(usdcScroll), 0, 1);
        vm.stopPrank();
    }

    function test_bridge_reverts_whenDestinationDataNotSet() public {
        IERC20 weth = IERC20(chainConfig.weth);
        deal(address(weth), address(settlementDispatcherReap), 1 ether);
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.DestinationDataNotSet.selector);
        settlementDispatcherReap.bridge(address(weth), 1, 1);
    }

    function test_bridge_reverts_whenInsufficientBalance() public {
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherReap)), 0);

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InsufficientBalance.selector);
        settlementDispatcherReap.bridge(address(usdcScroll), 1, 1);
    }

    function test_bridge_reverts_whenInsufficientFee() public {
        uint256 balBefore = 100e6;
        deal(address(usdcScroll), address(settlementDispatcherReap), balBefore);
        
        uint256 amount = 10e6;
        ( , uint256 valueToSend, , , ) = settlementDispatcherReap.prepareRideBus(address(usdcScroll), amount);

        deal(address(settlementDispatcherReap), valueToSend - 1);
        
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InsufficientFeeToCoverCost.selector);
        settlementDispatcherReap.bridge(address(usdcScroll), amount, 1);
    }

    function test_bridge_reverts_whenMinReturnTooHigh() public {
        uint256 balBefore = 100e6;
        deal(address(usdcScroll), address(settlementDispatcherReap), balBefore);
        uint256 amount = 10e6;
        ( , uint256 valueToSend, uint256 minReturnFromStargate, , ) = settlementDispatcherReap.prepareRideBus(address(usdcScroll), amount);
        deal(address(settlementDispatcherReap), valueToSend);
        
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InsufficientMinReturn.selector);
        settlementDispatcherReap.bridge(address(usdcScroll), amount, minReturnFromStargate + 1);
    }

    function test_withdrawFunds_succeeds_withErc20Token() public {
        deal(address(usdcScroll), address(settlementDispatcherReap), 1 ether);
        uint256 amount = 100e6;

        uint256 aliceBalBefore = usdcScroll.balanceOf(alice);
        uint256 safeBalBefore = usdcScroll.balanceOf(address(settlementDispatcherReap));
        
        vm.prank(owner);
        settlementDispatcherReap.withdrawFunds(address(usdcScroll), alice, amount);

        uint256 aliceBalAfter = usdcScroll.balanceOf(alice);
        uint256 safeBalAfter = usdcScroll.balanceOf(address(settlementDispatcherReap));

        assertEq(aliceBalAfter - aliceBalBefore, amount);
        assertEq(safeBalBefore - safeBalAfter, amount);

        // withdraw all
        vm.prank(owner);
        settlementDispatcherReap.withdrawFunds(address(usdcScroll), alice, 0);

        aliceBalAfter = usdcScroll.balanceOf(alice);
        safeBalAfter = usdcScroll.balanceOf(address(settlementDispatcherReap));

        assertEq(aliceBalAfter - aliceBalBefore, safeBalBefore);
        assertEq(safeBalAfter, 0);
    }

    function test_withdrawFunds_succeeds_withNativeToken() public {
        deal(address(settlementDispatcherReap), 1 ether);
        uint256 amount = 100e6;

        uint256 aliceBalBefore = alice.balance;
        uint256 safeBalBefore = address(settlementDispatcherReap).balance;
        
        vm.prank(owner);
        settlementDispatcherReap.withdrawFunds(address(0), alice, amount);

        uint256 aliceBalAfter = alice.balance;
        uint256 safeBalAfter = address(settlementDispatcherReap).balance;

        assertEq(aliceBalAfter - aliceBalBefore, amount);
        assertEq(safeBalBefore - safeBalAfter, amount);

        // withdraw all
        vm.prank(owner);
        settlementDispatcherReap.withdrawFunds(address(0), alice, 0);

        aliceBalAfter = alice.balance;
        safeBalAfter = address(settlementDispatcherReap).balance;

        assertEq(aliceBalAfter - aliceBalBefore, safeBalBefore);
        assertEq(safeBalAfter, 0);
    }

    function test_withdrawFunds_reverts_whenRecipientAddressZero() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.withdrawFunds(address(usdcScroll), address(0), 1);
    }

    function test_withdrawFunds_reverts_whenNoBalance() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.CannotWithdrawZeroAmount.selector);
        settlementDispatcherReap.withdrawFunds(address(usdcScroll), alice, 0);
        
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.CannotWithdrawZeroAmount.selector);
        settlementDispatcherReap.withdrawFunds(address(0), alice, 0);
    }

    function test_withdrawFunds_reverts_whenInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert();
        settlementDispatcherReap.withdrawFunds(address(usdcScroll), alice, 1);
        
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.WithdrawFundsFailed.selector);
        settlementDispatcherReap.withdrawFunds(address(0), alice, 1);
    }

    function getDestData() internal view returns (address[] memory tokens, SettlementDispatcher.DestinationData[] memory destDatas) {
        tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        destDatas = new SettlementDispatcher.DestinationData[](1);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: alice,
            stargate: stargateUsdcPool
        });
    }
}