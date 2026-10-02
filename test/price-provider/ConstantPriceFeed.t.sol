// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ConstantPriceFeed } from "../../src/oracle/ConstantPriceFeed.sol";

contract ConstantPriceFeedTest is Test {
    function test_reportsFixedAnswer() public {
        ConstantPriceFeed feed = new ConstantPriceFeed(1, 8, "placeholder 1 wei");
        assertEq(feed.latestAnswer(), 1);
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "placeholder 1 wei");
        vm.warp(block.timestamp + 365 days);
        assertEq(feed.latestAnswer(), 1);
    }

    function test_constructor_rejectsNonPositive() public {
        vm.expectRevert(ConstantPriceFeed.InvalidAnswer.selector);
        new ConstantPriceFeed(0, 8, "zero");
        vm.expectRevert(ConstantPriceFeed.InvalidAnswer.selector);
        new ConstantPriceFeed(-1, 8, "negative");
    }
}
