// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TopUpSourceMigrationBase } from "./TopUpSourceMigrationBase.s.sol";

/// @title UpgradeAndHandoverArbitrum
/// @notice STAKE-1676 migration for Arbitrum: upgrades TopUpSourceFactory to the GOVERNANCE_ROLE
///         impl, grants GOVERNANCE_ROLE to the safe, and moves RoleRegistry ownership to the
///         EtherFiTimelock via the two-step handover. See TimelockMigrationBase for details.
///
/// Usage:
///   forge script scripts/gnosis-txs/timelock-migration/UpgradeAndHandoverArbitrum.s.sol --rpc-url $ARBITRUM_RPC --ledger --broadcast --slow
///   # step1 JSON -> Safe UI now; step2 JSON -> Safe UI after the 2-day delay
contract UpgradeAndHandoverArbitrum is TopUpSourceMigrationBase {
    function requiredChainId() internal pure override returns (uint256) {
        return 42161;
    }

    function roleRegistry() internal pure override returns (address) {
        return 0x55963de88267Aa3D1D995c359e8068D0Df34BEBb;
    }
}
