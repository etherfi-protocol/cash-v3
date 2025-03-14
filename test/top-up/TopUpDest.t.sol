// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IEtherFiDataProvider } from "../../src/interfaces/IEtherFiDataProvider.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { UpgradeableProxy, PausableUpgradeable } from "../../src/utils/UpgradeableProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";

contract TopUpDestTest is Test {
    TopUpDest public topUpDest;
    RoleRegistry public roleRegistry;
    address public dataProvider;
    MockERC20 public token1;
    MockERC20 public token2;

    address public owner;
    address public depositor;
    address public topUpRole;
    address public pauser;
    address public unpauser;
    address public user1;
    address public user2;
    address public nonUser;

    bytes32 public constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    uint256 public constant INITIAL_AMOUNT = 1000 ether;
    uint256 public constant DEPOSIT_AMOUNT = 500 ether;
    uint256 public constant TOP_UP_AMOUNT = 100 ether;

    function setUp() public {
        owner = makeAddr("owner");
        depositor = makeAddr("depositor");
        topUpRole = makeAddr("topUpRole");
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        nonUser = makeAddr("nonUser");

        dataProvider = makeAddr("dataProvider");

        // Set up mock for EtherFiDataProvider
        vm.mockCall(dataProvider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, user1), abi.encode(true));
        vm.mockCall(dataProvider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, user2), abi.encode(true));

        // Reverts for non-safe addresses
        vm.mockCall(dataProvider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, nonUser), abi.encode(false));

        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        token1 = new MockERC20("Token 1", "TK1", 18);
        token2 = new MockERC20("Token 2", "TK2", 18);

        token1.mint(depositor, INITIAL_AMOUNT);
        token2.mint(depositor, INITIAL_AMOUNT);

        // Grant roles
        roleRegistry.grantRole(TOP_UP_DEPOSITOR_ROLE, depositor);
        roleRegistry.grantRole(TOP_UP_ROLE, topUpRole);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        // Deploy TopUpDest
        address topUpDestImpl = address(new TopUpDest());
        topUpDest = TopUpDest(address(new UUPSProxy(topUpDestImpl, abi.encodeWithSelector(TopUpDest.initialize.selector, address(roleRegistry), address(dataProvider)))));
        vm.stopPrank();

        // Approve tokens for depositing
        vm.startPrank(depositor);
        token1.approve(address(topUpDest), INITIAL_AMOUNT);
        token2.approve(address(topUpDest), INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(topUpDest.getEtherFiDataProvider(), address(dataProvider));
    }

    function test_deposit_succeeds() public {
        vm.startPrank(depositor);

        // Deposit token1
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        // Check state changes
        assertEq(topUpDest.getDeposit(address(token1)), DEPOSIT_AMOUNT);
        assertEq(token1.balanceOf(address(topUpDest)), DEPOSIT_AMOUNT);
        assertEq(token1.balanceOf(depositor), INITIAL_AMOUNT - DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    function test_deposit_fails_whenCallerNotDepositor() public {
        vm.startPrank(nonUser);

        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    function test_deposit_fails_withZeroAmount() public {
        vm.startPrank(depositor);

        vm.expectRevert(TopUpDest.AmountCannotBeZero.selector);
        topUpDest.deposit(address(token1), 0);

        vm.stopPrank();
    }

    function test_withdraw_succeeds() public {
        deal(address(token1), depositor, DEPOSIT_AMOUNT);
        
        // First deposit some tokens
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        uint256 ownerBalBefore = token1.balanceOf(owner);
        uint256 withdrawAmt = DEPOSIT_AMOUNT / 2;

        // Then withdraw
        vm.startPrank(owner);
        topUpDest.withdraw(address(token1), withdrawAmt);

        // Check state changes
        assertEq(topUpDest.getDeposit(address(token1)), withdrawAmt);
        assertEq(token1.balanceOf(address(topUpDest)), withdrawAmt);
        assertEq(token1.balanceOf(owner), ownerBalBefore + withdrawAmt);
        assertEq(token1.balanceOf(depositor), 0);

        vm.stopPrank();
    }

    function test_withdraw_fails_whenCallerNotOwner() public {
        // First deposit some tokens
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        vm.startPrank(nonUser);

        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        topUpDest.withdraw(address(token1), DEPOSIT_AMOUNT / 2);

        vm.stopPrank();
    }

    function test_withdraw_fails_withZeroAmount() public {
        vm.startPrank(owner);

        vm.expectRevert(TopUpDest.AmountCannotBeZero.selector);
        topUpDest.withdraw(address(token1), 0);

        vm.stopPrank();
    }

    function test_withdraw_fails_whenAmountExceedsDeposit() public {
        // First deposit some tokens
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        vm.startPrank(owner);

        vm.expectRevert(TopUpDest.AmountGreaterThanDeposit.selector);
        topUpDest.withdraw(address(token1), DEPOSIT_AMOUNT + 1);

        vm.stopPrank();
    }

    function test_topUpUserSafe_single_succeeds() public {
        // First deposit some tokens
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        // Then top up a user
        vm.startPrank(topUpRole);

        uint256 chainId = 100;

        vm.expectEmit(true, true, true, true);
        emit TopUpDest.TopUp(user1, chainId, address(token1), TOP_UP_AMOUNT, TOP_UP_AMOUNT);
        topUpDest.topUpUserSafe(user1, chainId, address(token1), TOP_UP_AMOUNT, 0);

        // Check state changes
        assertEq(topUpDest.getCumulativeTopUp(user1, chainId, address(token1)), TOP_UP_AMOUNT);
        assertEq(token1.balanceOf(user1), TOP_UP_AMOUNT);
        assertEq(token1.balanceOf(address(topUpDest)), DEPOSIT_AMOUNT - TOP_UP_AMOUNT);

        vm.stopPrank();
    }

    function test_topUpUserSafe_multiple_succeeds() public {
        // First deposit tokens
        vm.startPrank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);
        topUpDest.deposit(address(token2), DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Then top up multiple users
        vm.startPrank(topUpRole);

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user1; // Same user can be topped up multiple times

        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = 100;
        chainIds[1] = 200;
        chainIds[2] = 100; // Same chain ID for user1

        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token1); // Same token for user1

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = TOP_UP_AMOUNT;
        amounts[1] = TOP_UP_AMOUNT;
        amounts[2] = TOP_UP_AMOUNT;

        uint256[] memory cumulativeAmts = new uint256[](3);
        cumulativeAmts[0] = 0;
        cumulativeAmts[1] = 0;
        cumulativeAmts[2] = TOP_UP_AMOUNT;

        vm.expectEmit(true, true, true, true);
        emit TopUpDest.TopUp(users[0], chainIds[0], tokens[0], amounts[0], amounts[0]);
        vm.expectEmit(true, true, true, true);
        emit TopUpDest.TopUp(users[1], chainIds[1], tokens[1], amounts[1], amounts[1]);
        vm.expectEmit(true, true, true, true);
        emit TopUpDest.TopUp(users[2], chainIds[2], tokens[2], amounts[2], amounts[0] + amounts[2]);
        topUpDest.topUpUserSafeBatch(users, chainIds, tokens, amounts, cumulativeAmts);

        // Check state changes
        assertEq(topUpDest.getCumulativeTopUp(user1, 100, address(token1)), TOP_UP_AMOUNT * 2);
        assertEq(topUpDest.getCumulativeTopUp(user2, 200, address(token2)), TOP_UP_AMOUNT);
        assertEq(token1.balanceOf(user1), TOP_UP_AMOUNT * 2);
        assertEq(token2.balanceOf(user2), TOP_UP_AMOUNT);

        vm.stopPrank();
    }

    function test_topUpUserSafe_fails_whenCallerNotTopUpRole() public {
        vm.startPrank(nonUser);

        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        topUpDest.topUpUserSafe(user1, 100, address(token1), TOP_UP_AMOUNT, 0);

        vm.stopPrank();
    }

    function test_topUpUserSafe_fails_whenAddressNotRegisteredSafe() public {
        // First deposit some tokens
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        vm.startPrank(topUpRole);

        vm.expectRevert(TopUpDest.NotARegisteredSafe.selector);
        topUpDest.topUpUserSafe(nonUser, 100, address(token1), TOP_UP_AMOUNT, 0);

        vm.stopPrank();
    }

    function test_topUpUserSafe_fails_whenBalanceTooLow() public {
        // Deposit less than what we'll try to top up
        vm.prank(depositor);
        topUpDest.deposit(address(token1), TOP_UP_AMOUNT / 2);

        vm.startPrank(topUpRole);

        vm.expectRevert(TopUpDest.BalanceTooLow.selector);
        topUpDest.topUpUserSafe(user1, 100, address(token1), TOP_UP_AMOUNT, 0);

        vm.stopPrank();
    }

    function test_topUpUserSafe_fails_whenContractPaused() public {
        // First deposit some tokens
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        // Pause the contract
        vm.prank(pauser);
        topUpDest.pause();

        vm.startPrank(topUpRole);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        topUpDest.topUpUserSafe(user1, 100, address(token1), TOP_UP_AMOUNT, 0);

        vm.stopPrank();
    }

    function test_topUpUserSafe_multiple_fails_whenArrayLengthsMismatch() public {
        vm.startPrank(topUpRole);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 100;
        chainIds[1] = 200;

        address[] memory tokens = new address[](1); // Only one token
        tokens[0] = address(token1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = TOP_UP_AMOUNT;
        amounts[1] = TOP_UP_AMOUNT;

        vm.expectRevert(TopUpDest.ArrayLengthMismatch.selector);
        topUpDest.topUpUserSafeBatch(users, chainIds, tokens, amounts, amounts);

        vm.stopPrank();
    }

    function test_pause_unpause() public {
        // Pause the contract
        vm.prank(pauser);
        topUpDest.pause();

        // Check it's paused
        assertTrue(topUpDest.paused());

        // Unpause the contract
        vm.prank(unpauser);
        topUpDest.unpause();

        // Check it's unpaused
        assertFalse(topUpDest.paused());
    }

    function test_pause_fails_whenCallerNotPauser() public {
        vm.startPrank(nonUser);

        vm.expectRevert(); // Expect the check in onlyPauser to revert
        topUpDest.pause();

        vm.stopPrank();
    }

    function test_unpause_fails_whenCallerNotUnpauser() public {
        // First pause the contract
        vm.prank(pauser);
        topUpDest.pause();

        vm.startPrank(nonUser);

        vm.expectRevert(); // Expect the check in onlyUnpauser to revert
        topUpDest.unpause();

        vm.stopPrank();
    }

    function test_getters() public {
        // Deposit tokens
        vm.startPrank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);
        topUpDest.deposit(address(token2), DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Top up a user
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(user1, 100, address(token1), TOP_UP_AMOUNT, 0);

        // Check getDeposit
        assertEq(topUpDest.getDeposit(address(token1)), DEPOSIT_AMOUNT);
        assertEq(topUpDest.getDeposit(address(token2)), DEPOSIT_AMOUNT);

        // Check getCumulativeTopUp
        assertEq(topUpDest.getCumulativeTopUp(user1, 100, address(token1)), TOP_UP_AMOUNT);
        assertEq(topUpDest.getCumulativeTopUp(user1, 200, address(token1)), 0); // Different chain ID
        assertEq(topUpDest.getCumulativeTopUp(user1, 100, address(token2)), 0); // Different token
        assertEq(topUpDest.getCumulativeTopUp(user2, 100, address(token1)), 0); // Different user

        // Check getEtherFiDataProvider
        assertEq(topUpDest.getEtherFiDataProvider(), address(dataProvider));
    }
}
