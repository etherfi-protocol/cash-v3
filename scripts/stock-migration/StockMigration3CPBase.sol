// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { ISpokeLike, LendRails } from "../stock-listing/StockLendConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { StockMigrationFeedDeployer } from "./DeployStockMigrationFeeds.s.sol";
import { ILendTimelock, StockMigration } from "./StockMigrationConfig.sol";

/// @dev Shared plumbing for the migration's Summer Lend bundles.
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

    /// @dev Writes the Timelock Safe's schedule and execute bundles for one lend timelock batch and simulates
    ///      both, warping past the delay. The schedule is skipped when the batch is already queued live.
    function _writeTimelockBundles(string memory schedulePath, string memory executePath, bytes32 salt, address[] memory targets, bytes[] memory payloads) internal {
        ILendTimelock timelock = ILendTimelock(StockMigration.LEND_TIMELOCK);
        uint256[] memory values = new uint256[](targets.length);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        require(!timelock.isOperationDone(id), "timelock batch already executed");

        if (!timelock.isOperation(id)) {
            _writeTimelockSafeCall(schedulePath, abi.encodeCall(ILendTimelock.scheduleBatch, (targets, values, payloads, bytes32(0), salt, timelock.getMinDelay())));
            executeGnosisTransactionBundle(schedulePath);
        } else {
            console.log("Batch already scheduled live; writing the execute bundle only");
        }
        _writeTimelockSafeCall(executePath, abi.encodeCall(ILendTimelock.executeBatch, (targets, values, payloads, bytes32(0), salt)));

        if (block.timestamp < timelock.getTimestamp(id)) vm.warp(timelock.getTimestamp(id));
        executeGnosisTransactionBundle(executePath);
    }

    function _writeTimelockSafeCall(string memory path, bytes memory data) internal {
        vm.createDir("./output", true);
        vm.writeFile(path, _append(_getGnosisHeader(vm.toString(block.chainid), addressToHex(StockMigration.TIMELOCK_SAFE)), StockMigration.LEND_TIMELOCK, data, true));
        console.log("Written: %s", path);
    }
}
