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