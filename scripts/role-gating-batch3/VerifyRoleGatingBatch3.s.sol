// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { RoleGatingBatch3Checks } from "./RoleGatingBatch3Checks.sol";

/// @title VerifyRoleGatingBatch3
/// @notice Post-execution verifier for batch 3, run against the LIVE chain after the Safe has
///         executed multisend 2 and the trading bundle. Read-only, reverts on the first failure:
///           - every batch-3 proxy's EIP-1967 slot holds the exact CREATE3-predicted impl
///             (record cross-checked against the prediction, so a swapped impl is caught)
///           - CashModule setters / DebtManager admin point at the new delegated impls
///           - new modules are default, mirror the old requester status, are LendGateway drivers,
///             carry the liquid withdraw queues; old modules demoted but still whitelisted
///           - registry owners and timelock delays unchanged; ADMIN_ROLE / ADMIN_TIMELOCK_ROLE in place
///
/// Usage:
///   ENV=mainnet forge script scripts/role-gating-batch3/VerifyRoleGatingBatch3.s.sol --rpc-url $OPTIMISM_RPC
///   ENV=mainnet forge script scripts/role-gating-batch3/VerifyRoleGatingBatch3.s.sol --rpc-url $MAINNET_RPC
contract VerifyRoleGatingBatch3 is RoleGatingBatch3Checks {
    function run() public view {
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");
        if (block.chainid == 10) {
            _assertOpEndState(_readOpLive(), _readOpImpls());
        } else if (block.chainid == 1) {
            _assertEthEndState(_readEthLive(), _readEthImpls());
        } else {
            revert("VerifyRoleGatingBatch3: Optimism or Ethereum only");
        }
        console.log("=== Batch-3 verification passed ===");
    }
}
