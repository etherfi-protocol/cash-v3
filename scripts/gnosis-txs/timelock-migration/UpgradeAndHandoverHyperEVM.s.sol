// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TopUpSourceMigrationBase } from "./TopUpSourceMigrationBase.s.sol";

/// @title UpgradeAndHandoverHyperEVM
/// @notice STAKE-1676 migration for HyperEVM: upgrades TopUpSourceFactory to the GOVERNANCE_ROLE
///         impl, grants GOVERNANCE_ROLE to the safe, and moves RoleRegistry ownership to the
///         EtherFiTimelock via the two-step handover. See TimelockMigrationBase for details.
///
/// @dev IMPORTANT: the TopUpFactory impl deployment needs ~5.7M gas, which exceeds HyperEVM's
///      2M small-block limit. Enable big blocks for the deployer address on HyperCore
///      (evmUserModify { usingBigBlocks: true }) before running, or the deploy tx is rejected
///      with "intrinsic gas too high".
///
/// Usage:
///   forge script scripts/gnosis-txs/timelock-migration/UpgradeAndHandoverHyperEVM.s.sol --rpc-url $HYPEREVM_RPC --ledger --broadcast --slow
///   # step1 JSON -> Safe UI now; step2 JSON -> Safe UI after the 2-day delay
contract UpgradeAndHandoverHyperEVM is TopUpSourceMigrationBase {
    function requiredChainId() internal pure override returns (uint256) {
        return 999;
    }

    function roleRegistry() internal pure override returns (address) {
        return 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    }
}
