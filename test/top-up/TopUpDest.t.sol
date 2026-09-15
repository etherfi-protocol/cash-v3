// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IEtherFiDataProvider } from "../../src/interfaces/IEtherFiDataProvider.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { UpgradeableProxy, PausableUpgradeable } from "../../src/utils/UpgradeableProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { Constants } from "../../src/utils/Constants.sol";
import { Utils, ChainConfig } from "../utils/Utils.sol";

contract TopUpDestTest is Utils, Constants {
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
    address public weth;

    bytes32 public constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");
    bytes32 private constant TOP_UP_DEST_STORAGE_LOCATION = 0xcf0121b0f46cee8ebfce652f58f0ad785e4fcd91a62127b83995179fc450fe00;

    uint256 public constant INITIAL_AMOUNT = 1000 ether;
    uint256 public constant DEPOSIT_AMOUNT = 500 ether;
    uint256 public constant TOP_UP_AMOUNT = 100 ether;

    function setUp() public {
        ChainConfig memory chainConfig = getChainConfig();

        string memory rpc;
        try vm.envString("TEST_RPC") returns (string memory testRpc) {
            rpc = bytes(testRpc).length > 0 ? testRpc : chainConfig.rpc;
        } catch {
            rpc = chainConfig.rpc;
        }
        vm.createSelectFork(rpc);

        weth = chainConfig.weth;
        owner = makeAddr("owner");
        depositor = makeAddr("depositor");
        topUpRole = makeAddr("topUpRole");
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
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

        token1 = new MockERC20("Token 1", "TK1", 18);
        token2 = new MockERC20("Token 2", "TK2", 18);
        token1.mint(depositor, INITIAL_AMOUNT);
        token2.mint(depositor, INITIAL_AMOUNT);

        roleRegistry.grantRole(TOP_UP_DEPOSITOR_ROLE, depositor);
        roleRegistry.grantRole(TOP_UP_ROLE, topUpRole);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        address topUpDestImpl = address(new TopUpDest(address(dataProvider), weth));
        topUpDest = TopUpDest(payable(address(new UUPSProxy(topUpDestImpl, abi.encodeWithSelector(TopUpDest.initialize.selector, address(roleRegistry))))));
        vm.stopPrank();

        vm.startPrank(depositor);
        token1.approve(address(topUpDest), INITIAL_AMOUNT);
        token2.approve(address(topUpDest), INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function test_deposit_succeeds() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        assertEq(topUpDest.getDeposit(address(token1)), DEPOSIT_AMOUNT);
        assertEq(token1.balanceOf(address(topUpDest)), DEPOSIT_AMOUNT);
    }

    function test_withdraw_succeeds() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        vm.prank(owner);
        topUpDest.withdraw(address(token1), DEPOSIT_AMOUNT / 2);

        assertEq(topUpDest.getDeposit(address(token1)), DEPOSIT_AMOUNT / 2);
    }

    function test_topUpUserSafe_usesChainAwareTxId() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        uint256 chainId = 100;
        bytes32 txHash = keccak256("transaction1");
        bytes32 txId = topUpDest.getChainAwareTxId(chainId, txHash, user1, address(token1));

        vm.expectEmit(true, true, true, true);
        emit TopUpDest.TopUp(txId, user1, address(token1), txHash, chainId, TOP_UP_AMOUNT);
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(txHash, user1, chainId, address(token1), TOP_UP_AMOUNT);

        assertTrue(topUpDest.isChainAwareTransactionCompleted(chainId, txHash, user1, address(token1)));
        assertTrue(topUpDest.isTransactionCompletedByTxId(txId));
        assertFalse(topUpDest.isTransactionCompleted(txHash, user1, address(token1)));
        assertEq(token1.balanceOf(user1), TOP_UP_AMOUNT);
    }

    function test_topUpUserSafe_sameSourceTxOnDifferentChains_succeedsOncePerChain() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        bytes32 txHash = keccak256("same-source-tx");
        uint256 chainIdA = 100;
        uint256 chainIdB = 200;

        bytes32 txIdA = topUpDest.getChainAwareTxId(chainIdA, txHash, user1, address(token1));
        bytes32 txIdB = topUpDest.getChainAwareTxId(chainIdB, txHash, user1, address(token1));
        assertTrue(txIdA != txIdB);

        vm.startPrank(topUpRole);
        topUpDest.topUpUserSafe(txHash, user1, chainIdA, address(token1), TOP_UP_AMOUNT);
        topUpDest.topUpUserSafe(txHash, user1, chainIdB, address(token1), TOP_UP_AMOUNT);

        assertTrue(topUpDest.isChainAwareTransactionCompleted(chainIdA, txHash, user1, address(token1)));
        assertTrue(topUpDest.isChainAwareTransactionCompleted(chainIdB, txHash, user1, address(token1)));
        assertEq(token1.balanceOf(user1), TOP_UP_AMOUNT * 2);

        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        topUpDest.topUpUserSafe(txHash, user1, chainIdA, address(token1), TOP_UP_AMOUNT);
        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        topUpDest.topUpUserSafe(txHash, user1, chainIdB, address(token1), TOP_UP_AMOUNT);
        vm.stopPrank();
    }

    function test_topUpUserSafe_rejectsLegacyCompletedTransaction() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        bytes32 txHash = keccak256("legacy-top-up");
        bytes32 legacyTxId = topUpDest.getTxId(txHash, user1, address(token1));
        bytes32 legacyMappingSlot = keccak256(abi.encode(legacyTxId, TOP_UP_DEST_STORAGE_LOCATION));
        vm.store(address(topUpDest), legacyMappingSlot, bytes32(uint256(1)));

        assertTrue(topUpDest.isTransactionCompleted(txHash, user1, address(token1)));
        assertTrue(topUpDest.isChainAwareTransactionCompleted(100, txHash, user1, address(token1)));

        vm.prank(topUpRole);
        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        topUpDest.topUpUserSafe(txHash, user1, 100, address(token1), TOP_UP_AMOUNT);

        assertEq(token1.balanceOf(user1), 0);
        assertFalse(topUpDest.isTransactionCompletedByTxId(topUpDest.getChainAwareTxId(100, txHash, user1, address(token1))));
    }

    function test_topUpUserSafeBatch_usesChainAwareIds() public {
        vm.startPrank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);
        topUpDest.deposit(address(token2), DEPOSIT_AMOUNT);
        vm.stopPrank();

        bytes32[] memory txHashes = new bytes32[](2);
        txHashes[0] = keccak256("batch-1");
        txHashes[1] = keccak256("batch-2");
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 100;
        chainIds[1] = 200;
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = TOP_UP_AMOUNT;
        amounts[1] = TOP_UP_AMOUNT;

        vm.prank(topUpRole);
        topUpDest.topUpUserSafeBatch(txHashes, users, chainIds, tokens, amounts);

        assertTrue(topUpDest.isChainAwareTransactionCompleted(chainIds[0], txHashes[0], users[0], tokens[0]));
        assertTrue(topUpDest.isChainAwareTransactionCompleted(chainIds[1], txHashes[1], users[1], tokens[1]));
        assertEq(token1.balanceOf(user1), TOP_UP_AMOUNT);
        assertEq(token2.balanceOf(user2), TOP_UP_AMOUNT);
    }

    function test_topUpUserSafe_fails_whenCallerNotTopUpRole() public {
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        vm.prank(nonUser);
        topUpDest.topUpUserSafe(keccak256("tx"), user1, 100, address(token1), TOP_UP_AMOUNT);
    }

    function test_topUpUserSafe_fails_whenAddressNotRegisteredSafe() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);

        vm.expectRevert(TopUpDest.NotARegisteredSafe.selector);
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(keccak256("tx"), nonUser, 100, address(token1), TOP_UP_AMOUNT);
    }

    function test_topUpUserSafe_fails_whenBalanceTooLow() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), TOP_UP_AMOUNT / 2);

        vm.expectRevert(TopUpDest.BalanceTooLow.selector);
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(keccak256("tx"), user1, 100, address(token1), TOP_UP_AMOUNT);
    }

    function test_topUpUserSafe_fails_whenContractPaused() public {
        vm.prank(depositor);
        topUpDest.deposit(address(token1), DEPOSIT_AMOUNT);
        vm.prank(pauser);
        topUpDest.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(topUpRole);
        topUpDest.topUpUserSafe(keccak256("tx"), user1, 100, address(token1), TOP_UP_AMOUNT);
    }

    function test_topUpUserSafeBatch_fails_whenArrayLengthsMismatch() public {
        bytes32[] memory txHashes = new bytes32[](2);
        address[] memory users = new address[](2);
        uint256[] memory chainIds = new uint256[](2);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](2);

        vm.expectRevert(TopUpDest.ArrayLengthMismatch.selector);
        vm.prank(topUpRole);
        topUpDest.topUpUserSafeBatch(txHashes, users, chainIds, tokens, amounts);
    }

    function test_pause_unpause() public {
        vm.prank(pauser);
        topUpDest.pause();
        assertTrue(topUpDest.paused());

        vm.prank(unpauser);
        topUpDest.unpause();
        assertFalse(topUpDest.paused());
    }

    function test_getTxId_remainsLegacy() public view {
        bytes32 txHash = keccak256("test_transaction");
        bytes32 expectedTxId = keccak256(abi.encode(txHash, user1, address(token1)));
        assertEq(topUpDest.getTxId(txHash, user1, address(token1)), expectedTxId);
    }

    function test_getChainAwareTxId_includesChainId() public view {
        bytes32 txHash = keccak256("test_transaction");
        bytes32 expectedTxId = keccak256(abi.encode(uint256(100), txHash, user1, address(token1)));
        assertEq(topUpDest.getChainAwareTxId(100, txHash, user1, address(token1)), expectedTxId);
        assertTrue(topUpDest.getChainAwareTxId(100, txHash, user1, address(token1)) != topUpDest.getChainAwareTxId(200, txHash, user1, address(token1)));
    }

    function test_receive_depositsEthAsWeth() public {
        uint256 amount = 1 ether;
        deal(address(owner), amount);
        uint256 balanceBefore = IERC20(weth).balanceOf(address(topUpDest));

        vm.prank(owner);
        (bool success, ) = address(topUpDest).call{value: amount}("");
        assertTrue(success);

        assertEq(IERC20(weth).balanceOf(address(topUpDest)) - balanceBefore, amount);
    }
}
