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
import { IEtherFiDataProvider } from "../../../../../src/interfaces/IEtherFiDataProvider.sol";
import { IBoringOnChainQueue } from "../../../../../src/interfaces/IBoringOnChainQueue.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { MessagingFee } from "../../../../../src/interfaces/IStargate.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { SettlementDispatcher } from "../../../../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { Constants } from "../../../../../src/utils/Constants.sol";

contract SettlementDispatcherTest is CashModuleTestSetup, Constants {
    address alice = makeAddr("alice");

    address liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address boringQueueLiquidUsd = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
    uint16 discount = 1;
    uint24 secondsToDeadline = 3 days;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.LiquidWithdrawQueueSet(liquidUsd, address(boringQueueLiquidUsd));
        settlementDispatcherReap.setLiquidAssetWithdrawQueue(liquidUsd, address(boringQueueLiquidUsd));
    }


    function test_getRefundWallet_returnsCorrectAddress() public {
        // Initially should be address(0)
        assertEq(settlementDispatcherReap.getRefundWallet(), refundWallet);
        
        address newWallet = makeAddr("newWallet");
        // Set refund wallet
        vm.prank(owner);
        dataProvider.setRefundWallet(newWallet);
        
        // Should return the set address
        assertEq(settlementDispatcherReap.getRefundWallet(), newWallet);
    }

    function test_transferFundsToRefundWallet_succeeds_withErc20Token() public {        
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
        // Fund the contract with ETH
        uint256 amount = 1 ether;
        deal(address(settlementDispatcherReap), amount);
        
        // Track balances before transfer
        uint256 walletBalBefore = refundWallet.balance;
        uint256 dispatcherBalBefore = address(settlementDispatcherReap).balance;
        
        // Transfer funds
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.TransferToRefundWallet(ETH, refundWallet, amount);
        settlementDispatcherReap.transferFundsToRefundWallet(ETH, amount);
        
        // Check balances after transfer
        uint256 walletBalAfter = refundWallet.balance;
        uint256 dispatcherBalAfter = address(settlementDispatcherReap).balance;
        
        assertEq(walletBalAfter - walletBalBefore, amount);
        assertEq(dispatcherBalBefore - dispatcherBalAfter, amount);
    }

    function test_transferFundsToRefundWallet_transferAllTokens_withAmountZero() public {        
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
        // Attempt to transfer with zero balance
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.CannotWithdrawZeroAmount.selector);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), 0);
    }


    function test_transferFundsToRefundWallet_reverts_whenRefundWalletNotSet() public {
        // Unset refund wallet
        vm.mockCall(
            address(dataProvider),
            abi.encodeWithSelector(IEtherFiDataProvider.getRefundWallet.selector),
            abi.encode(address(0))
        );
        
        // Fund the contract
        deal(address(usdcScroll), address(settlementDispatcherReap), 100e6);
        
        // Attempt to transfer
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.RefundWalletNotSet.selector);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), 100e6);
    }

    function test_transferFundsToRefundWallet_reverts_whenCallerNotBridger() public {        
        // Fund the contract
        deal(address(usdcScroll), address(settlementDispatcherReap), 100e6);
        
        // Attempt to transfer as non-bridger
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), 100e6);
    }

    function test_transferFundsToRefundWallet_reverts_whenInsufficientBalance() public {        
        // Fund the contract with less than we'll try to transfer
        uint256 amount = 50e6;
        deal(address(usdcScroll), address(settlementDispatcherReap), amount);
        
        // Attempt to transfer more than available
        vm.prank(owner);
        vm.expectRevert();
        settlementDispatcherReap.transferFundsToRefundWallet(address(usdcScroll), amount * 2);
    }

    function test_setLiquidAssetWithdrawQueue_setsTheConfig() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.LiquidWithdrawQueueSet(liquidUsd, address(boringQueueLiquidUsd));
        settlementDispatcherReap.setLiquidAssetWithdrawQueue(liquidUsd, address(boringQueueLiquidUsd));
    }
    
    function test_setLiquidAssetWithdrawQueue_fails_ifSetterNotRoleRegistryOwner() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawQueue(liquidUsd, address(boringQueueLiquidUsd));
    }

    function test_setLiquidAssetWithdrawQueue_fails_ifBoringQueueIsNotCorrect() public {
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InvalidBoringQueue.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawQueue(address(usdcScroll), address(boringQueueLiquidUsd));
    }
    
    function test_setLiquidAssetWithdrawQueue_fails_ForZeroAddresses() public {
        vm.startPrank(owner);
        
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawQueue(address(0), address(boringQueueLiquidUsd));
                
        vm.expectRevert(SettlementDispatcher.InvalidValue.selector);
        settlementDispatcherReap.setLiquidAssetWithdrawQueue(liquidUsd, address(0));

        vm.stopPrank();
    }

    function test_getLiquidAssetWithdrawQueue_returns_correctQueueAddress() public view {
        assertEq(settlementDispatcherReap.getLiquidAssetWithdrawQueue(address(liquidUsd)), address(boringQueueLiquidUsd));
    }

    function test_withdrawLiquidAsset_succeeds() public {
        uint128 amount = 100e6;
        uint128 minReturn = 100e6;

        deal(liquidUsd, address(settlementDispatcherReap), amount);

        uint128 amountOut = IBoringOnChainQueue(boringQueueLiquidUsd).previewAssetsOut(address(usdcScroll), amount, discount);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcher.LiquidWithdrawalRequested(liquidUsd, address(usdcScroll), amount, amountOut);
        settlementDispatcherReap.withdrawLiquidAsset(liquidUsd, address(usdcScroll), amount, minReturn, discount, secondsToDeadline);

        assertEq(IERC20(liquidUsd).balanceOf(address(settlementDispatcherReap)), 0);
    }

    function test_withdrawLiquidAsset_fails_ifConfigNotSet() public {
        uint128 amount = 100e6;
        uint128 minReturn = 100e6;

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.LiquidWithdrawConfigNotSet.selector);
        settlementDispatcherReap.withdrawLiquidAsset(address(usdcScroll), address(usdcScroll), amount, minReturn, discount, secondsToDeadline);
    }

    function test_withdrawLiquidAsset_fails_ifInsufficientReturnAmount() public {
        uint128 amount = 100e6;
        uint128 minReturn = 150e6;

        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.InsufficientReturnAmount.selector);
        settlementDispatcherReap.withdrawLiquidAsset(address(liquidUsd), address(usdcScroll), amount, minReturn, discount, secondsToDeadline);
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

    function test_bridge_worksWithEth() public {
        address[] memory tokens = new address[](1); 
        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);

        tokens[0] = ETH;
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: address(1),
            stargate: address(stargateEthPool),
            useCanonicalBridge: false,
            minGasLimit: 0
        });

        vm.prank(owner);
        settlementDispatcherReap.setDestinationData(tokens, destDatas);

        uint256 balBefore = 1 ether;
        deal(address(settlementDispatcherReap), balBefore);
        
        uint256 amount = 0.1 ether;
        ( , , , , MessagingFee memory messagingFee) = settlementDispatcherReap.prepareRideBus(ETH, amount);

        deal(address(settlementDispatcherReap), balBefore + messagingFee.nativeFee);
        
        uint256 stargateBalBefore = address(stargateEthPool).balance;
        
        vm.prank(owner);
        settlementDispatcherReap.bridge(ETH, amount, 1);

        uint256 stargateBalAfter = address(stargateEthPool).balance;

        assertEq(address(settlementDispatcherReap).balance, balBefore - amount);
        assertGt(stargateBalAfter, stargateBalBefore);
    }

    function test_bridge_works_withCanonicalBridge() public {
        uint256 balBefore = 1e6;
        deal(address(usdtScroll), address(settlementDispatcherRain), balBefore);
        deal(address(usdcScroll), address(settlementDispatcherRain), balBefore);

        vm.startPrank(owner);
        settlementDispatcherRain.bridge(address(usdtScroll), balBefore, 1);
        assertEq(usdtScroll.balanceOf(address(settlementDispatcherRain)), 0);
        
        address[] memory tokens = new address[](1);
        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);

        tokens[0] = address(usdcScroll);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: owner,
            stargate: stargateUsdcPool,
            useCanonicalBridge: true,
            minGasLimit: 200_000
        });
        settlementDispatcherRain.setDestinationData(tokens, destDatas);

        settlementDispatcherRain.bridge(address(usdcScroll), balBefore, 1);
        assertEq(usdcScroll.balanceOf(address(settlementDispatcherRain)), 0);
    }

    function test_bridge_works_withCanonicalBridge_ETH() public {
        uint256 balBefore = 1e6;
        deal(address(settlementDispatcherRain), balBefore);

        address[] memory tokens = new address[](1);
        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);

        tokens[0] = address(ETH);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: owner,
            stargate: stargateEthPool,
            useCanonicalBridge: true,
            minGasLimit: 200_000
        });

        vm.prank(owner);
        settlementDispatcherRain.setDestinationData(tokens, destDatas);

        vm.prank(owner);
        settlementDispatcherRain.bridge(address(ETH), balBefore, 1);
        assertEq(address(settlementDispatcherRain).balance, 0);
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
        settlementDispatcherReap.withdrawFunds(ETH, alice, amount);

        uint256 aliceBalAfter = alice.balance;
        uint256 safeBalAfter = address(settlementDispatcherReap).balance;

        assertEq(aliceBalAfter - aliceBalBefore, amount);
        assertEq(safeBalBefore - safeBalAfter, amount);

        // withdraw all
        vm.prank(owner);
        settlementDispatcherReap.withdrawFunds(ETH, alice, 0);

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
        settlementDispatcherReap.withdrawFunds(ETH, alice, 0);
    }

    function test_withdrawFunds_reverts_whenInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert();
        settlementDispatcherReap.withdrawFunds(address(usdcScroll), alice, 1);
        
        vm.prank(owner);
        vm.expectRevert(SettlementDispatcher.WithdrawFundsFailed.selector);
        settlementDispatcherReap.withdrawFunds(ETH, alice, 1);
    }

    function getDestData() internal view returns (address[] memory tokens, SettlementDispatcher.DestinationData[] memory destDatas) {
        tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        destDatas = new SettlementDispatcher.DestinationData[](1);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: alice,
            stargate: stargateUsdcPool,
            useCanonicalBridge: false,
            minGasLimit: 0
        });
    }
}
