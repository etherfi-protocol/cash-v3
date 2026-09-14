// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ISpokeLike, LendRails } from "../stock-listing/StockLendConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { StockMigrationFeedDeployer } from "./DeployStockMigrationFeeds.s.sol";

/// @dev Shared plumbing for the migration's Lend Owner Safe bundles.
abstract contract StockMigration3CPBase is GnosisHelpers, Test, StockMigrationFeedDeployer {
    function _requireOptimismProd() internal view {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
    }

    function _reserveIdOf(address token) internal view returns (uint256) {
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        return type(uint256).max;
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
