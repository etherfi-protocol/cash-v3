// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title WithdrawCapacityTest
 * @notice Boundary tests for the gateway's Aave-priced withdraw-headroom family: the quoted capacity is
 *         exactly executable on Aave, and a hair more fails Aave's own health check.
 * @dev Run with: FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/WithdrawCapacity.t.sol
 */
contract WithdrawCapacityTest is CashGatewayTestSetup {
    /// The raw-headroom capacity is exactly executable after interest accrual: withdrawing it passes
    /// Aave's health check and a hair more reverts on it (the share-rounding proof's empirical gate).
    function testFuzz_withdrawCapacity_exactlyExecutable(uint256 borrowBps) public {
        borrowBps = bound(borrowBps, 1000, 9000);
        _supplyToGateway(address(safe), address(weETH), 10 ether);
        uint256 borrow = (gw.getAccountData(address(safe)).availableBorrowsUsd * borrowBps) / 10_000;
        _borrowOnGateway(address(safe), address(usdc), borrow, recipient);
        vm.warp(block.timestamp + 1 hours); // accrue interest (within oracle staleness) so the share math sits off round numbers

        uint256 cap = gw.collateralForHeadroom(address(safe), address(weETH), gw.rawWithdrawHeadroom(address(safe)));
        assertGt(cap, 0, "healthy position quotes capacity");
        assertLt(cap, 10 ether, "debt keeps part of the collateral");

        vm.prank(driver);
        vm.expectRevert(ISpoke.HealthFactorBelowThreshold.selector);
        gw.withdraw(address(safe), address(weETH), cap + 0.001 ether, recipient);

        vm.prank(driver);
        gw.withdraw(address(safe), address(weETH), cap, recipient);
        assertGe(spoke.getUserAccountData(address(safe)).healthFactor, 1e18, "landed at or above Aave's bound");
    }

    /// The buffered quote sits strictly inside the raw one once a floor is set.
    function test_bufferedCapacity_insideRaw() public {
        _supplyToGateway(address(safe), address(weETH), 10 ether);
        _borrowOnGateway(address(safe), address(usdc), gw.getAccountData(address(safe)).availableBorrowsUsd / 2, recipient);
        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);

        uint256 buffered = gw.collateralForHeadroom(address(safe), address(weETH), gw.withdrawHeadroom(address(safe)));
        uint256 raw = gw.collateralForHeadroom(address(safe), address(weETH), gw.rawWithdrawHeadroom(address(safe)));
        assertLt(buffered, raw, "floor shrinks the withdrawable quote");
        assertGt(buffered, 0, "healthy position keeps a buffered quote");
    }
}
