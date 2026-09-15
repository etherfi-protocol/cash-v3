// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TopUpDestTest } from "./TopUpDest.t.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";

contract TopUpDestChainAwareTxIdTest is TopUpDestTest {
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
        assertTrue(topUpDest.isTransactionCompletedByTxId(txIdA));
        assertTrue(topUpDest.isTransactionCompletedByTxId(txIdB));
        assertEq(token1.balanceOf(user1), TOP_UP_AMOUNT * 2);

        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        topUpDest.topUpUserSafe(txHash, user1, chainIdA, address(token1), TOP_UP_AMOUNT);

        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        topUpDest.topUpUserSafe(txHash, user1, chainIdB, address(token1), TOP_UP_AMOUNT);
        vm.stopPrank();
    }
}
