// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TopUpSourceMigrationBase } from "./TopUpSourceMigrationBase.s.sol";

/// @title UpgradeAndHandoverBNB
/// @notice STAKE-1676 migration for BNB: upgrades TopUpSourceFactory to the GOVERNANCE_ROLE
///         impl, grants GOVERNANCE_ROLE to the safe, and moves RoleRegistry ownership to the
///         EtherFiTimelock via the two-step handover. See TimelockMigrationBase for details.
///
/// Usage:
///   forge script scripts/gnosis-txs/timelock-migration/UpgradeAndHandoverBNB.s.sol --rpc-url $BSC_RPC --ledger --broadcast --slow
///   # step1 JSON -> Safe UI now; step2 JSON -> Safe UI after the 2-day delay
contract UpgradeAndHandoverBNB is TopUpSourceMigrationBase {
    function requiredChainId() internal pure override returns (uint256) {
        return 56;
    }

    function roleRegistry() internal pure override returns (address) {
        return 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    }
}
