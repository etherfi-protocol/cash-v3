// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import { PixWalletAutoTopup, Ownable, IERC20, UUPSUpgradeable } from "../../src/pix-auto-topup/PixWalletAutoTopup.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";

contract PixWalletAutoTopupTest is Test {
    PixWalletAutoTopup public pixWalletAutoTopup;
    address public owner = makeAddr("owner");
    address public pixWalletOnBase = makeAddr("pixWalletOnBase");

    function setUp() public {
        string memory mainnetRpc = vm.envString("MAINNET_RPC");
        if (bytes(mainnetRpc).length == 0) mainnetRpc = "https://mainnet.gateway.tenderly.co";
        
        vm.createSelectFork(mainnetRpc);
        address pixWalletAutoTopupImpl = address(new PixWalletAutoTopup());
        pixWalletAutoTopup = PixWalletAutoTopup(address(new UUPSProxy(pixWalletAutoTopupImpl, abi.encodeWithSelector(PixWalletAutoTopup.initialize.selector, owner, pixWalletOnBase))));
    }

    function test_initialize() public view {
        assertEq(pixWalletAutoTopup.owner(), owner);
        assertEq(pixWalletAutoTopup.pixWalletOnBase(), pixWalletOnBase);
    }

    function test_setPixWalletOnBase() public {
        address newPixWalletOnBase = makeAddr("newPixWalletOnBase");
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PixWalletAutoTopup.PixWalletSet(pixWalletOnBase, newPixWalletOnBase);
        pixWalletAutoTopup.setPixWalletOnBase(newPixWalletOnBase);
        assertEq(pixWalletAutoTopup.pixWalletOnBase(), newPixWalletOnBase);

        vm.prank(owner);
        vm.expectRevert(PixWalletAutoTopup.InvalidInput.selector);
        pixWalletAutoTopup.setPixWalletOnBase(address(0));

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        pixWalletAutoTopup.setPixWalletOnBase(newPixWalletOnBase);
    }

    function test_bridgeViaCCTP() public {
        uint256 amount = 10e6;
        deal(pixWalletAutoTopup.USDC(), address(pixWalletAutoTopup), amount);
 
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PixWalletAutoTopup.BridgeViaCCTP(pixWalletAutoTopup.USDC(), amount, pixWalletAutoTopup.CCTP_DEST_DOMAIN_BASE(), bytes32(uint256(uint160(pixWalletOnBase))));
        pixWalletAutoTopup.bridgeViaCCTP(amount);

        uint256 balance = IERC20(pixWalletAutoTopup.USDC()).balanceOf(address(pixWalletAutoTopup));
        assertEq(balance, 0);
    }

    function test_bridgeViaCCTP_whenAmountIsGreaterThanBalance() public {
        uint256 amount = 10e6;
        uint256 balance = amount / 2;
        deal(pixWalletAutoTopup.USDC(), address(pixWalletAutoTopup), balance);

        vm.expectEmit(true, true, true, true);
        emit PixWalletAutoTopup.BridgeViaCCTP(pixWalletAutoTopup.USDC(), balance, pixWalletAutoTopup.CCTP_DEST_DOMAIN_BASE(), bytes32(uint256(uint160(pixWalletOnBase))));
        pixWalletAutoTopup.bridgeViaCCTP(amount);

        uint256 balanceAfter = IERC20(pixWalletAutoTopup.USDC()).balanceOf(address(pixWalletAutoTopup));
        assertEq(balanceAfter, 0);
    }

    function test_onlyOwnerCanUpgradeTheContract() public {
        address newImplementation = address(new PixWalletAutoTopup());
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        UUPSUpgradeable(address(pixWalletAutoTopup)).upgradeToAndCall(newImplementation, "");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IERC1967.Upgraded(newImplementation);
        UUPSUpgradeable(address(pixWalletAutoTopup)).upgradeToAndCall(newImplementation, "");
    }
}