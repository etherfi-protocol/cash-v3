// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { Constants } from "../../src/utils/Constants.sol";

contract TopUpTest is Test, Constants {
    TopUp public topUp;
    address public owner;
    address public user;
    MockERC20 public token;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        topUp = new TopUp();
        token = new MockERC20("Test Token", "TEST");

        topUp.initialize(owner);
    }

    /// @dev Test processTopUp functionality
    function test_processTopUp_transfersAllFundsToOwner() public {
        // Setup test tokens and ETH
        token.mint(address(topUp), 100);
        vm.deal(address(topUp), 1 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = ETH; // ETH

        vm.prank(owner);
        topUp.processTopUp(tokens);

        assertEq(token.balanceOf(address(topUp)), 0, "TopUp contract should have 0 tokens");
        assertEq(address(topUp).balance, 0, "TopUp contract should have 0 ETH");
        assertEq(token.balanceOf(owner), 100, "Owner should have received tokens");
        assertEq(owner.balance, 1 ether, "Owner should have received ETH");
    }

    /// @dev Test non-owner cannot pull funds
    function test_processTopUp_reverts_whenCalledByNonOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        vm.prank(user);
        vm.expectRevert(TopUp.OnlyOwner.selector);
        topUp.processTopUp(tokens);
    }

    /// @dev Test cannot initialize twice
    function test_initialize_reverts_whenCalledTwice() public {
        vm.expectRevert();
        topUp.initialize(owner);
    }
}
