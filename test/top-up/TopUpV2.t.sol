// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract TopUpV2Test is Test {
    TopUpV2 public topup;
    MockERC20 public token;

    address public dispatcher = makeAddr("dispatcher");
    address public weth = makeAddr("weth");
    address public factory = makeAddr("factory");

    function setUp() public {
        // `executeRecovery` only depends on DISPATCHER; the TopUp impl ships with
        // `owner() = 0xdead` (set in TopUp's constructor), so no initialize is needed here.
        // Integration with the beacon / proxy is exercised in the E2E test.
        topup = new TopUpV2(weth, dispatcher);
        token = new MockERC20("Mock", "MOCK", 18);

        token.mint(address(topup), 100e18);
    }

    function test_executeRecovery_transfersTokenToRecipient() public {
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, false, true);
        emit TopUpV2.RecoveryExecuted(address(token), recipient, 40e18);

        vm.prank(dispatcher);
        topup.executeRecovery(address(token), 40e18, recipient);

        assertEq(token.balanceOf(recipient), 40e18, "recipient balance mismatch");
        assertEq(token.balanceOf(address(topup)), 60e18, "topup balance mismatch");
    }

    function test_executeRecovery_revertsIfNotDispatcher() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(TopUpV2.OnlyDispatcher.selector);
        topup.executeRecovery(address(token), 40e18, makeAddr("recipient"));
    }

    function test_executeRecovery_revertsOnZeroRecipient() public {
        vm.prank(dispatcher);
        vm.expectRevert(TopUpV2.InvalidRecipient.selector);
        topup.executeRecovery(address(token), 40e18, address(0));
    }

    function test_executeRecovery_revertsOnZeroAmount() public {
        vm.prank(dispatcher);
        vm.expectRevert(TopUpV2.InvalidAmount.selector);
        topup.executeRecovery(address(token), 0, makeAddr("recipient"));
    }

    function test_executeRecovery_bubblesSafeTransferRevert() public {
        // Ask for more than the proxy holds — SafeERC20 should revert the call.
        vm.prank(dispatcher);
        vm.expectRevert();
        topup.executeRecovery(address(token), 1_000e18, makeAddr("recipient"));
    }

    function test_dispatcherImmutableSetInConstructor() public view {
        assertEq(topup.DISPATCHER(), dispatcher);
    }
}
