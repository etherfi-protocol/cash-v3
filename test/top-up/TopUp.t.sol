// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { Constants } from "../../src/utils/Constants.sol";

contract WETH is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

contract TopUpTest is Test, Constants {
    TopUp public topUp;
    address public owner;
    address public user;
    MockERC20 public token;
    WETH public weth;

    function setUp() public {
        owner = 0x000000000000000000000000000000000000dEaD;
        user = makeAddr("user");
        weth = new WETH();
        topUp = new TopUp(address(weth));
        token = new MockERC20("Test Token", "TEST", 18);

        // topUp.initialize(owner);
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
        vm.expectEmit(true, true, true, true);
        emit TopUp.ProcessTopUp(address(token), 100);
        vm.expectEmit(true, true, true, true);
        emit TopUp.ProcessTopUp(address(weth), 1 ether);
        topUp.processTopUp(tokens);

        assertEq(token.balanceOf(address(topUp)), 0, "TopUp contract should have 0 tokens");
        assertEq(weth.balanceOf(address(topUp)), 0, "TopUp contract should have 0 ETH");
        assertEq(token.balanceOf(owner), 100, "Owner should have received tokens");
        assertEq(weth.balanceOf(owner), 1 ether, "Owner should have received ETH");
    }

    function test_ETH_transfers_convertItToWeth() public {
        uint256 amount = 1 ether;
        vm.deal(address(owner), amount);

        assertEq(weth.balanceOf(payable(address(topUp))), 0);
        assertEq(payable(address(topUp)).balance, 0);

        vm.prank(owner);
        (bool success, ) = payable(address(topUp)).call{value: amount}("");
        assertTrue(success, "ETH transfer failed");

        assertEq(weth.balanceOf(payable(address(topUp))), amount);
        assertEq(payable(address(topUp)).balance, 0);
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
