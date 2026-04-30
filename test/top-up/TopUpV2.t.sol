// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";

contract TopUpV2Test is Test {
    TopUpV2 public topup;
    MockERC20 public token;

    address public dispatcher = makeAddr("dispatcher");
    address public weth = makeAddr("weth");
    address public factory = makeAddr("factory");

    function setUp() public {
        // The TopUp impl ships with `owner() = 0xdead` (set in TopUp's constructor); in prod
        // a beacon proxy calls `initialize(factory)` so `owner()` is the local `TopUpFactory`.
        // Here we stub `TopUpFactory.isTokenSupported(token) = false` on the dead address so
        // `executeRecovery` doesn't trip the new `OnlyUnsupportedTokens` guard. The
        // `revertsIfTokenSupported` test overrides this stub. Beacon-proxy integration is
        // exercised in the E2E test.
        topup = new TopUpV2(weth, dispatcher);
        token = new MockERC20("Mock", "MOCK", 18);

        vm.mockCall(
            address(0xdead),
            abi.encodeWithSignature("isTokenSupported(address)", address(token)),
            abi.encode(false)
        );

        token.mint(address(topup), 100e18);
    }

    function test_executeRecovery_transfersFullBalanceToRecipient() public {
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, false, true);
        emit TopUpV2.RecoveryExecuted(address(token), recipient, 100e18);

        vm.prank(dispatcher);
        topup.executeRecovery(address(token), recipient);

        assertEq(token.balanceOf(recipient), 100e18, "recipient balance mismatch");
        assertEq(token.balanceOf(address(topup)), 0, "topup should be drained");
    }

    function test_executeRecovery_sweepsActualBalanceIncludingPostSubmitDust() public {
        // Previously dust arriving between submit + delivery would brick the call. With the
        // amount-less payload the contract sweeps whatever is sitting here at receipt time.
        token.mint(address(topup), 1); // dust arrived after the Safe signed
        address recipient = makeAddr("recipient");

        vm.prank(dispatcher);
        topup.executeRecovery(address(token), recipient);

        assertEq(token.balanceOf(recipient), 100e18 + 1, "should sweep original + dust");
        assertEq(token.balanceOf(address(topup)), 0, "topup should be drained");
    }

    function test_executeRecovery_revertsIfNoBalance() public {
        // Drain the topup first so balanceOf == 0.
        vm.prank(dispatcher);
        topup.executeRecovery(address(token), makeAddr("recipient"));

        vm.prank(dispatcher);
        vm.expectRevert(TopUpV2.NoBalanceToRecover.selector);
        topup.executeRecovery(address(token), makeAddr("recipient"));
    }

    function test_executeRecovery_revertsIfNotDispatcher() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(TopUpV2.OnlyDispatcher.selector);
        topup.executeRecovery(address(token), makeAddr("recipient"));
    }

    function test_executeRecovery_revertsOnZeroRecipient() public {
        vm.prank(dispatcher);
        vm.expectRevert(TopUpV2.InvalidRecipient.selector);
        topup.executeRecovery(address(token), address(0));
    }

    function test_executeRecovery_revertsIfTokenSupported() public {
        // Supported tokens have a working bridge route and must be moved through the normal
        // claim path. The recovery path is only for funds stuck on a chain with no route.
        vm.mockCall(
            address(0xdead),
            abi.encodeWithSignature("isTokenSupported(address)", address(token)),
            abi.encode(true)
        );

        vm.prank(dispatcher);
        vm.expectRevert(TopUpV2.OnlyUnsupportedTokens.selector);
        topup.executeRecovery(address(token), makeAddr("recipient"));
    }

    function test_dispatcherImmutableSetInConstructor() public view {
        assertEq(topup.DISPATCHER(), dispatcher);
    }
}
