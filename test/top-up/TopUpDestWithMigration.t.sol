// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IEtherFiDataProvider } from "../../src/interfaces/IEtherFiDataProvider.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { UpgradeableProxy, PausableUpgradeable } from "../../src/utils/UpgradeableProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { TopUpDestWithMigration } from "../../src/top-up/TopUpDestWithMigration.sol";

contract TopUpDestWithMigrationTest is Test {
    TopUpDestWithMigration public topUpDest;
    RoleRegistry public roleRegistry;
    address public dataProvider;
    MockERC20 public token;

    address public owner;
    address public depositor;
    address public topUpRole;
    address public migrationModule;
    address public user1;
    address public user2;
    address public nonUser;

    bytes32 public constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    uint256 public constant DEPOSIT_AMOUNT = 500 ether;
    uint256 public constant TOP_UP_AMOUNT = 100 ether;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io";
        vm.createSelectFork(scrollRpc);

        owner = makeAddr("owner");
        depositor = makeAddr("depositor");
        topUpRole = makeAddr("topUpRole");
        migrationModule = makeAddr("migrationModule");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        nonUser = makeAddr("nonUser");

        dataProvider = makeAddr("dataProvider");

        vm.mockCall(dataProvider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, user1), abi.encode(true));
        vm.mockCall(dataProvider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, user2), abi.encode(true));
        vm.mockCall(dataProvider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, nonUser), abi.encode(false));

        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        token = new MockERC20("Token", "TK", 18);
        token.mint(depositor, 1000 ether);

        roleRegistry.grantRole(TOP_UP_DEPOSITOR_ROLE, depositor);
        roleRegistry.grantRole(TOP_UP_ROLE, topUpRole);

        // Deploy as TopUpDest first, then upgrade to V2 (mimics real upgrade path)
        address topUpDestImpl = address(new TopUpDest(dataProvider));
        address proxy = address(new UUPSProxy(topUpDestImpl, abi.encodeWithSelector(TopUpDest.initialize.selector, address(roleRegistry))));

        // Upgrade to V2
        address topUpDestV2Impl = address(new TopUpDestWithMigration(dataProvider, migrationModule));
        UUPSUpgradeable(proxy).upgradeToAndCall(topUpDestV2Impl, "");

        topUpDest = TopUpDestWithMigration(proxy);

        vm.stopPrank();

        vm.startPrank(depositor);
        token.approve(address(topUpDest), 1000 ether);
        topUpDest.deposit(address(token), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    // ── setMigrated ──

    function test_setMigrated_succeeds_whenCalledByMigrationModule() public {
        address[] memory safes = new address[](2);
        safes[0] = user1;
        safes[1] = user2;

        vm.expectEmit(true, true, true, true);
        emit TopUpDestWithMigration.SafeMigrationSet(user1, true);
        vm.expectEmit(true, true, true, true);
        emit TopUpDestWithMigration.SafeMigrationSet(user2, true);

        vm.prank(migrationModule);
        topUpDest.setMigrated(safes);

        assertTrue(topUpDest.isMigrated(user1));
        assertTrue(topUpDest.isMigrated(user2));
    }

    function test_setMigrated_reverts_whenCalledByNonMigrationModule() public {
        address[] memory safes = new address[](1);
        safes[0] = user1;

        vm.prank(owner);
        vm.expectRevert(TopUpDestWithMigration.OnlyMigrationModule.selector);
        topUpDest.setMigrated(safes);
    }

    function test_setMigrated_reverts_whenSafeNotRegistered() public {
        address[] memory safes = new address[](1);
        safes[0] = nonUser;

        vm.prank(migrationModule);
        vm.expectRevert(TopUpDest.NotARegisteredSafe.selector);
        topUpDest.setMigrated(safes);
    }

    // ── unsetMigrated ──

    function test_unsetMigrated_succeeds_whenCalledByOwner() public {
        // First migrate
        address[] memory safes = new address[](1);
        safes[0] = user1;
        vm.prank(migrationModule);
        topUpDest.setMigrated(safes);
        assertTrue(topUpDest.isMigrated(user1));

        // Then unset
        vm.expectEmit(true, true, true, true);
        emit TopUpDestWithMigration.SafeMigrationSet(user1, false);

        vm.prank(owner);
        topUpDest.unsetMigrated(safes);

        assertFalse(topUpDest.isMigrated(user1));
    }

    function test_unsetMigrated_reverts_whenCalledByNonOwner() public {
        address[] memory safes = new address[](1);
        safes[0] = user1;

        vm.prank(nonUser);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        topUpDest.unsetMigrated(safes);
    }

    // ── topUp blocked for migrated safes ──

    function test_topUp_reverts_whenSafeMigrated() public {
        // Migrate user1
        address[] memory safes = new address[](1);
        safes[0] = user1;
        vm.prank(migrationModule);
        topUpDest.setMigrated(safes);

        // Try to top up migrated safe
        vm.prank(topUpRole);
        vm.expectRevert(TopUpDestWithMigration.SafeMigrated.selector);
        topUpDest.topUpUserSafe(keccak256("tx"), user1, 100, address(token), TOP_UP_AMOUNT);
    }

    function test_topUp_succeeds_whenSafeNotMigrated() public {
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(keccak256("tx"), user1, 100, address(token), TOP_UP_AMOUNT);

        assertEq(token.balanceOf(user1), TOP_UP_AMOUNT);
    }

    function test_topUp_succeeds_afterUnsetMigrated() public {
        // Migrate
        address[] memory safes = new address[](1);
        safes[0] = user1;
        vm.prank(migrationModule);
        topUpDest.setMigrated(safes);

        // Verify blocked
        vm.prank(topUpRole);
        vm.expectRevert(TopUpDestWithMigration.SafeMigrated.selector);
        topUpDest.topUpUserSafe(keccak256("tx1"), user1, 100, address(token), TOP_UP_AMOUNT);

        // Unset migration
        vm.prank(owner);
        topUpDest.unsetMigrated(safes);

        // Now succeeds
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(keccak256("tx2"), user1, 100, address(token), TOP_UP_AMOUNT);
        assertEq(token.balanceOf(user1), TOP_UP_AMOUNT);
    }

    function test_topUpBatch_reverts_whenAnySafeMigrated() public {
        // Migrate user1 only
        address[] memory migrateSafes = new address[](1);
        migrateSafes[0] = user1;
        vm.prank(migrationModule);
        topUpDest.setMigrated(migrateSafes);

        // Batch with user1 (migrated) and user2 (not migrated)
        bytes32[] memory txHashes = new bytes32[](2);
        txHashes[0] = keccak256("tx1");
        txHashes[1] = keccak256("tx2");
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 100;
        chainIds[1] = 100;
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = TOP_UP_AMOUNT;
        amounts[1] = TOP_UP_AMOUNT;

        vm.prank(topUpRole);
        vm.expectRevert(TopUpDestWithMigration.SafeMigrated.selector);
        topUpDest.topUpUserSafeBatch(txHashes, users, chainIds, tokens, amounts);
    }

    // ── isMigrated ──

    function test_isMigrated_returnsFalse_byDefault() public view {
        assertFalse(topUpDest.isMigrated(user1));
        assertFalse(topUpDest.isMigrated(user2));
    }

    // ── migrationModule immutable ──

    function test_migrationModule_isSetCorrectly() public view {
        assertEq(topUpDest.migrationModule(), migrationModule);
    }

    // ── upgrade preserves existing TopUpDest functionality ──

    function test_existingFunctionality_worksAfterUpgrade() public {
        // deposit already happened in setUp
        assertEq(topUpDest.getDeposit(address(token)), DEPOSIT_AMOUNT);

        // top up works
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(keccak256("tx"), user1, 100, address(token), TOP_UP_AMOUNT);
        assertEq(token.balanceOf(user1), TOP_UP_AMOUNT);

        // withdraw works
        vm.prank(owner);
        topUpDest.withdraw(address(token), 50 ether);
    }
}
